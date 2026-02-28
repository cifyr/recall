import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { requireUser } from '../_shared/auth.ts';
import { requireString, requireUuid } from '../_shared/validation.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { requireOwnedSession } from '../_shared/db.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('update-session-notes', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const body = await parseJson<Record<string, unknown>>(request);
    const sessionId = requireUuid(body.session_id, 'session_id');
    const notes = requireString(body.notes, 'notes', 10000);
    await requireOwnedSession(sessionId, authUser.id);

    const serviceClient = createServiceClient();
    const { data: existing } = await serviceClient
      .from('conversation_notes')
      .select('version')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .maybeSingle();

    const { error } = await serviceClient.from('conversation_notes').upsert({
      session_id: sessionId,
      user_id: authUser.id,
      note_text: notes,
      version: (existing?.version ?? 0) + 1,
      request_id: context.requestId,
      updated_at: new Date().toISOString(),
    }, {
      onConflict: 'session_id,user_id',
    });

    if (error) {
      throw new AppError('notes_update_failed', error.message, 500);
    }

    return {
      response: success({
        session_id: sessionId,
        notes_updated: true,
      }, context.requestId),
      userId: authUser.id,
      correlationId: context.correlationId,
    };
  });
});
