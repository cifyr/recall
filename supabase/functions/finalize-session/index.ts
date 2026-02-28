import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { getInternalSecretForInternalCalls, requireUser } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { requireUuid } from '../_shared/validation.ts';
import { success } from '../_shared/response.ts';
import {
  getIdempotencyResponse,
  insertStageTransition,
  requireOwnedSession,
  upsertIdempotencyResponse,
} from '../_shared/db.ts';
import { emitEvents } from '../_shared/telemetry.ts';
import { sha256 } from '../_shared/idempotency.ts';
import { checkRateLimit } from '../_shared/rate-limit.ts';
import { env } from '../_shared/env.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('finalize-session', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const internalSecret = await getInternalSecretForInternalCalls();
    const body = await parseJson<Record<string, unknown>>(request);
    const requestHash = await sha256(body);
    const sessionId = requireUuid(body.session_id, 'session_id');

    const existingIdempotency = await getIdempotencyResponse({
      userId: authUser.id,
      actionKey: 'finalize_session',
      idempotencyKey: context.idempotencyKey,
    });
    if (existingIdempotency?.first_response && existingIdempotency.request_hash === requestHash) {
      return {
        response: success(existingIdempotency.first_response, context.requestId),
        userId: authUser.id,
        correlationId: context.correlationId,
      };
    }

    const finalizeLimit = await checkRateLimit('user', authUser.id, 'finalize_session', context.requestId);
    if (!finalizeLimit.allowed) {
      throw new AppError('rate_limit_exceeded', 'Finalize rate limit exceeded', 429, {
        retry_after_seconds: finalizeLimit.retry_after_seconds,
      });
    }

    const serviceClient = createServiceClient();
    const session = await requireOwnedSession(sessionId, authUser.id);
    if (['uploaded', 'transcribing', 'transcribed', 'summarizing', 'summarized'].includes(session.status)) {
      const payload = {
        session_id: sessionId,
        status: session.status,
        pipeline: {
          transcription_enqueued: true,
        },
      };
      await upsertIdempotencyResponse({
        userId: authUser.id,
        actionKey: 'finalize_session',
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

    const { data: segments, error: segmentsError } = await serviceClient
      .from('conversation_segments')
      .select('id, upload_status')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id);

    if (segmentsError) {
      throw new AppError('session_not_ready', segmentsError.message, 500);
    }

    if (!segments || segments.length === 0) {
      throw new AppError('session_not_ready', 'Session has no segments', 409);
    }

    if (segments.some((segment) => segment.upload_status !== 'uploaded')) {
      throw new AppError('session_not_ready', 'Session still has pending uploads', 409);
    }

    await serviceClient
      .from('conversation_sessions')
      .update({
        status: 'uploaded',
        ended_at: session.ended_at ?? new Date().toISOString(),
        latest_error_code: null,
        latest_error_message: null,
        request_id: context.requestId,
      })
      .eq('id', sessionId)
      .eq('user_id', authUser.id);

    await insertStageTransition({
      sessionId,
      userId: authUser.id,
      fromStatus: session.status,
      toStatus: 'uploaded',
      reason: 'user_finalize',
      requestId: context.requestId,
      correlationId: context.correlationId,
      actorPlatform: context.platform,
    });

    await emitEvents(
      [
        {
          event_name: 'session_finalize_succeeded',
          event_version: 1,
          occurred_at: new Date().toISOString(),
          conversation_session_id: sessionId,
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

    const triggerResponse = await fetch(`${env.supabaseUrl}/functions/v1/transcribe-session`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-internal-job-secret': internalSecret,
        'x-request-id': context.requestId,
        'x-correlation-id': context.correlationId ?? session.correlation_id ?? context.requestId,
        'x-platform': 'edge',
      },
      body: JSON.stringify({
        session_id: sessionId,
      }),
    });

    if (!triggerResponse.ok) {
      throw new AppError('transcription_enqueue_failed', 'Failed to enqueue transcription', 502);
    }

    const payload = {
      session_id: sessionId,
      status: 'uploaded',
      pipeline: {
        transcription_enqueued: true,
      },
    };

    await upsertIdempotencyResponse({
      userId: authUser.id,
      actionKey: 'finalize_session',
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
