import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { requireUser } from '../_shared/auth.ts';
import { requireNonNegativeInt, requireString, requireUuid } from '../_shared/validation.ts';
import { AppError } from '../_shared/errors.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { buildSegmentStoragePath, segmentPublicUploadUrl } from '../_shared/storage.ts';
import { success } from '../_shared/response.ts';
import { requireOwnedSession, upsertIdempotencyResponse, getIdempotencyResponse } from '../_shared/db.ts';
import { emitEvents } from '../_shared/telemetry.ts';
import { sha256 } from '../_shared/idempotency.ts';
import { checkRateLimit } from '../_shared/rate-limit.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('create-upload-ticket', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const body = await parseJson<Record<string, unknown>>(request);
    const requestHash = await sha256(body);

    const existingIdempotency = await getIdempotencyResponse({
      userId: authUser.id,
      actionKey: 'create_upload_ticket',
      idempotencyKey: context.idempotencyKey,
    });
    if (existingIdempotency?.first_response && existingIdempotency.request_hash === requestHash) {
      return {
        response: success(existingIdempotency.first_response, context.requestId),
        userId: authUser.id,
        correlationId: context.correlationId,
      };
    }

    const sessionId = requireUuid(body.session_id, 'session_id');
    const segmentIndex = requireNonNegativeInt(body.segment_index, 'segment_index');
    const fileExt = typeof body.file_ext === 'string' ? body.file_ext.replace(/^\./, '') : 'm4a';
    requireString(body.content_type ?? 'audio/m4a', 'content_type', 100);

    const userLimit = await checkRateLimit('user', authUser.id, 'create_upload_ticket', context.requestId);
    if (!userLimit.allowed) {
      throw new AppError('rate_limit_exceeded', 'Upload ticket rate limit exceeded', 429, {
        retry_after_seconds: userLimit.retry_after_seconds,
      });
    }

    await requireOwnedSession(sessionId, authUser.id);
    const serviceClient = createServiceClient();
    const { data: segment, error: segmentError } = await serviceClient
      .from('conversation_segments')
      .select('id, storage_path')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .eq('segment_index', segmentIndex)
      .maybeSingle();

    if (segmentError) {
      throw new AppError('segment_lookup_failed', segmentError.message, 500);
    }

    const storagePath = segment?.storage_path ?? buildSegmentStoragePath(authUser.id, sessionId, segmentIndex, fileExt);

    const { data: previousTickets, error: previousError } = await serviceClient
      .from('watch_upload_tickets')
      .select('*')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .eq('segment_index', segmentIndex)
      .eq('issued_to_device_id', context.deviceId)
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(1);

    if (previousError) {
      throw new AppError('ticket_lookup_failed', previousError.message, 500);
    }

    if (previousTickets && previousTickets.length > 0) {
      const existingTicket = previousTickets[0];
      const payload = {
        session_id: sessionId,
        segment_index: segmentIndex,
        storage_path: existingTicket.storage_path,
        signed_upload_url: existingTicket.signed_upload_url,
        expires_at: existingTicket.expires_at,
      };
      await upsertIdempotencyResponse({
        userId: authUser.id,
        actionKey: 'create_upload_ticket',
        idempotencyKey: context.idempotencyKey,
        requestHash,
        response: payload,
      });
      return {
        response: success(payload, context.requestId),
        userId: authUser.id,
        correlationId: context.correlationId,
      };
    }

    const { data: uploadData, error: uploadError } = await serviceClient.storage
      .from('conversation-audio')
      .createSignedUploadUrl(storagePath);

    if (uploadError || !uploadData?.signedUrl) {
      throw new AppError('ticket_issue_failed', uploadError?.message ?? 'Unable to create signed upload URL', 500);
    }

    const payload = {
      session_id: sessionId,
      segment_index: segmentIndex,
      storage_path: storagePath,
      signed_upload_url: segmentPublicUploadUrl(uploadData.signedUrl),
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    };

    const { error: insertTicketError } = await serviceClient.from('watch_upload_tickets').insert({
      user_id: authUser.id,
      session_id: sessionId,
      segment_index: segmentIndex,
      storage_path: storagePath,
      signed_upload_url: payload.signed_upload_url,
      expires_at: payload.expires_at,
      issued_to_device_id: context.deviceId,
      request_id: context.requestId,
    });

    if (insertTicketError) {
      throw new AppError('ticket_issue_failed', insertTicketError.message, 500);
    }

    await serviceClient
      .from('conversation_segments')
      .upsert({
        session_id: sessionId,
        user_id: authUser.id,
        segment_index: segmentIndex,
        storage_path: storagePath,
        upload_status: 'ticket_issued',
        request_id: context.requestId,
      }, {
        onConflict: 'session_id,segment_index',
      });

    await emitEvents(
      [
        {
          event_name: 'segment_upload_ticket_issued',
          event_version: 1,
          occurred_at: new Date().toISOString(),
          conversation_session_id: sessionId,
          properties: {
            segment_index: segmentIndex,
          },
        },
      ],
      authUser,
      {
        deviceId: context.deviceId,
        platform: context.platform,
        appVersion: context.appVersion,
        osVersion: context.osVersion,
        requestId: context.requestId,
        correlationId: context.correlationId,
      },
    );

    await upsertIdempotencyResponse({
      userId: authUser.id,
      actionKey: 'create_upload_ticket',
      idempotencyKey: context.idempotencyKey,
      requestHash,
      response: payload,
    });

    return {
      response: success(payload, context.requestId),
      userId: authUser.id,
      correlationId: context.correlationId,
    };
  });
});
