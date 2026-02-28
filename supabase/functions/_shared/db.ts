import { AppError } from './errors.ts';
import { createServiceClient } from './clients.ts';

export async function requireOwnedSession(sessionId: string, userId: string) {
  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient
    .from('conversation_sessions')
    .select('*')
    .eq('id', sessionId)
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    throw new AppError('session_lookup_failed', error.message, 500);
  }

  if (!data) {
    throw new AppError('session_not_found', 'Session not found', 404);
  }

  return data;
}

export async function insertFailure(input: {
  sessionId: string;
  userId: string;
  stage: string;
  errorCode: string;
  errorMessage?: string;
  requestId?: string;
  correlationId?: string | null;
  retryAfterSeconds?: number | null;
  isRetryable?: boolean;
}) {
  const serviceClient = createServiceClient();
  await serviceClient.from('conversation_failures').insert({
    session_id: input.sessionId,
    user_id: input.userId,
    stage: input.stage,
    error_code: input.errorCode,
    error_message: input.errorMessage ?? null,
    is_retryable: input.isRetryable ?? true,
    retry_after_seconds: input.retryAfterSeconds ?? null,
    request_id: input.requestId ?? null,
    correlation_id: input.correlationId ?? null,
  });

  await serviceClient
    .from('conversation_sessions')
    .update({
      status: 'failed',
      latest_error_code: input.errorCode,
      latest_error_message: input.errorMessage ?? null,
    })
    .eq('id', input.sessionId)
    .eq('user_id', input.userId);
}

export async function insertStageTransition(input: {
  sessionId: string;
  userId: string;
  fromStatus?: string | null;
  toStatus: string;
  reason?: string;
  requestId?: string;
  correlationId?: string | null;
  actorPlatform?: string;
}) {
  const serviceClient = createServiceClient();
  await serviceClient.from('session_stage_transitions').insert({
    session_id: input.sessionId,
    user_id: input.userId,
    from_status: input.fromStatus ?? null,
    to_status: input.toStatus,
    reason: input.reason ?? null,
    request_id: input.requestId ?? null,
    correlation_id: input.correlationId ?? null,
    actor_platform: input.actorPlatform ?? null,
  });
}

export async function upsertIdempotencyResponse(input: {
  userId: string;
  actionKey: string;
  idempotencyKey: string;
  requestHash: string;
  response: unknown;
}) {
  const serviceClient = createServiceClient();
  await serviceClient.from('idempotency_keys').upsert({
    user_id: input.userId,
    action_key: input.actionKey,
    idempotency_key: input.idempotencyKey,
    request_hash: input.requestHash,
    first_response: input.response,
  }, {
    onConflict: 'user_id,action_key,idempotency_key',
  });
}

export async function getIdempotencyResponse(input: {
  userId: string;
  actionKey: string;
  idempotencyKey: string;
}) {
  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient
    .from('idempotency_keys')
    .select('first_response, request_hash')
    .eq('user_id', input.userId)
    .eq('action_key', input.actionKey)
    .eq('idempotency_key', input.idempotencyKey)
    .maybeSingle();

  if (error) {
    throw new AppError('idempotency_lookup_failed', error.message, 500);
  }

  return data;
}
