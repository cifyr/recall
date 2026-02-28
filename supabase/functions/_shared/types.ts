export type AuthUser = {
  id: string;
  email?: string;
};

export type RateLimitOutcome = {
  allowed: boolean;
  retry_after_seconds: number | null;
  mode: 'monitor' | 'enforce';
  current_count: number;
  max_requests: number;
  triggered_rule_id: string | null;
};

export type EventInput = {
  event_id?: string;
  event_name: string;
  event_version: number;
  occurred_at: string;
  app_session_id?: string;
  conversation_session_id?: string;
  properties?: Record<string, unknown>;
};
