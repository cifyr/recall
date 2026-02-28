import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { requireUser } from '../_shared/auth.ts';
import { AppError } from '../_shared/errors.ts';
import { emitEvents } from '../_shared/telemetry.ts';
import { success } from '../_shared/response.ts';
import { checkRateLimit } from '../_shared/rate-limit.ts';
import { createServiceClient } from '../_shared/clients.ts';
import type { EventInput } from '../_shared/types.ts';
import { requireObject } from '../_shared/validation.ts';

const EVENT_ALLOWLIST = new Set([
  'auth_signed_in',
  'auth_signed_out',
  'watch_recording_started',
  'watch_recording_stopped',
  'watch_session_finalized',
  'segment_upload_ticket_requested',
  'segment_upload_started',
  'segment_upload_succeeded',
  'segment_upload_failed',
  'segment_upload_ticket_issued',
  'segment_upload_reconciled',
  'segment_upload_reconcile_failed',
  'session_finalize_requested',
  'session_finalize_succeeded',
  'session_finalize_failed',
  'session_status_updated',
  'session_notes_updated',
  'question_asked',
  'question_answered',
  'question_failed',
]);

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('ingest-events', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const body = await parseJson<{ events?: EventInput[] }>(request);
    const events = body.events ?? [];
    if (!Array.isArray(events)) {
      throw new AppError('invalid_payload', 'events must be an array', 400);
    }
    if (events.length > 200) {
      throw new AppError('batch_too_large', 'events batch exceeds 200 items', 413);
    }

    const limit = await checkRateLimit('device', context.deviceId, 'ingest_events', context.requestId);
    if (!limit.allowed) {
      throw new AppError('rate_limit_exceeded', 'Event ingest rate limit exceeded', 429);
    }

    const validEvents: EventInput[] = [];
    const rejected: Array<{ event_id?: string; code: string }> = [];

    for (const event of events) {
      if (!EVENT_ALLOWLIST.has(event.event_name)) {
        rejected.push({ event_id: event.event_id, code: 'invalid_event_name' });
        continue;
      }
      if (typeof event.event_version !== 'number') {
        rejected.push({ event_id: event.event_id, code: 'event_schema_violation' });
        continue;
      }
      try {
        if (event.properties !== undefined) {
          requireObject(event.properties, 'properties');
        }
        validEvents.push({
          ...event,
          properties: event.properties ?? {},
        });
      } catch (_error) {
        rejected.push({ event_id: event.event_id, code: 'event_schema_violation' });
      }
    }

    await emitEvents(validEvents, authUser, {
      deviceId: context.deviceId,
      platform: context.platform,
      appVersion: context.appVersion,
      osVersion: context.osVersion,
      requestId: context.requestId,
      correlationId: context.correlationId,
    });

    const serviceClient = createServiceClient();
    await serviceClient.from('event_ingest_batches').insert({
      user_id: authUser.id,
      device_id: context.deviceId,
      request_id: context.requestId,
      batch_size: events.length,
      accepted_count: validEvents.length,
      rejected_count: rejected.length,
      first_event_at: validEvents[0]?.occurred_at ?? null,
      last_event_at: validEvents[validEvents.length - 1]?.occurred_at ?? null,
    });

    return {
      response: success({
        accepted: validEvents.length,
        rejected: rejected.length,
        errors: rejected,
      }, context.requestId),
      userId: authUser.id,
      correlationId: context.correlationId,
    };
  });
});
