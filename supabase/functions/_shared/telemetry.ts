import { createServiceClient } from './clients.ts';
import type { AuthUser, EventInput } from './types.ts';

type InvocationInput = {
  functionName: string;
  userId?: string;
  requestId: string;
  correlationId?: string | null;
  statusCode: number;
  durationMs: number;
  result: 'ok' | 'error';
  errorCode?: string | null;
  errorMessage?: string | null;
};

export async function recordFunctionInvocation(input: InvocationInput): Promise<void> {
  const serviceClient = createServiceClient();
  await serviceClient.from('function_invocations').insert({
    function_name: input.functionName,
    user_id: input.userId ?? null,
    request_id: input.requestId,
    correlation_id: input.correlationId ?? null,
    status_code: input.statusCode,
    duration_ms: input.durationMs,
    result: input.result,
    error_code: input.errorCode ?? null,
    error_message: input.errorMessage ?? null,
  });
}

export async function emitEvents(
  events: EventInput[],
  authUser: AuthUser | null,
  meta: {
    deviceId: string;
    platform: string;
    appVersion: string;
    osVersion: string;
    requestId: string;
    correlationId?: string | null;
  },
): Promise<void> {
  if (events.length === 0) {
    return;
  }

  const serviceClient = createServiceClient();
  await serviceClient.from('app_events').insert(
    events.map((event) => ({
      event_id: event.event_id ?? null,
      user_id: authUser?.id ?? null,
      device_id: meta.deviceId,
      platform: meta.platform,
      event_name: event.event_name,
      event_version: event.event_version,
      app_session_id: event.app_session_id ?? null,
      conversation_session_id: event.conversation_session_id ?? null,
      request_id: meta.requestId,
      correlation_id: meta.correlationId ?? null,
      occurred_at: event.occurred_at,
      properties: event.properties ?? {},
      app_version: meta.appVersion,
      os_version: meta.osVersion,
    })),
  );
}

export function redactForLog(value: unknown): unknown {
  if (typeof value === 'string') {
    return value.length > 24 ? '[redacted]' : value;
  }
  if (Array.isArray(value)) {
    return value.map(redactForLog);
  }
  if (value && typeof value === 'object') {
    const output: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) {
      if (
        ['authorization', 'token', 'signed_upload_url', 'transcript_text', 'question', 'answer', 'note_text']
          .includes(key)
      ) {
        output[key] = '[redacted]';
      } else {
        output[key] = redactForLog(entry);
      }
    }
    return output;
  }
  return value;
}
