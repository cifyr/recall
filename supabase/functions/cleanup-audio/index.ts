import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext } from '../_shared/request.ts';
import { requireInternalSecret } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { env } from '../_shared/env.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('cleanup-audio', context.requestId, async () => {
    assertMethod(request, 'POST');
    await requireInternalSecret(request);
    const serviceClient = createServiceClient();
    const cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();

    const { data: expiredSegments, error } = await serviceClient
      .from('conversation_segments')
      .select('storage_path, session_id, user_id')
      .lt('created_at', cutoff)
      .eq('upload_status', 'uploaded')
      .limit(200);

    if (error) {
      throw error;
    }

    const paths = (expiredSegments ?? []).map((segment) => segment.storage_path);
    if (paths.length > 0) {
      await serviceClient.storage.from(env.audioBucket).remove(paths);
    }

    return {
      response: success({
        deleted_count: paths.length,
      }, context.requestId),
    };
  });
});
