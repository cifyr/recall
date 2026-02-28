import { AppError } from './errors.ts';
import { createServiceClient } from './clients.ts';
import type { RateLimitOutcome } from './types.ts';

export async function checkRateLimit(
  scopeType: 'user' | 'device' | 'ip',
  scopeId: string,
  actionKey: string,
  requestId: string,
): Promise<RateLimitOutcome> {
  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient.rpc('check_rate_limit', {
    p_scope_type: scopeType,
    p_scope_id: scopeId,
    p_action_key: actionKey,
    p_request_id: requestId,
  });

  if (error) {
    throw new AppError('rate_limit_error', error.message, 500);
  }

  const outcome = Array.isArray(data) ? data[0] : data;
  if (!outcome) {
    return {
      allowed: true,
      retry_after_seconds: null,
      mode: 'monitor',
      current_count: 0,
      max_requests: 0,
      triggered_rule_id: null,
    };
  }

  return outcome as RateLimitOutcome;
}
