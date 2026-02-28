# 02) Data Model and Storage

Split from: `IMPLEMENTATION_BLUEPRINT.md`  
Last updated: `2026-02-26`

## 5) Data model (Supabase-first, modular, track-everything)

### 5.1 Core data strategy

1. Supabase is the only backend system of record in v1:
- identity and sessions in Supabase Auth
- relational state in Supabase Postgres
- binary audio/artifacts in Supabase Storage

2. Locked data decisions from answered questions:
- English-only language scope (`en`) for v1.
- Raw audio retained short-term (`30 days` default).
- Transcript/summary/Q&A/notes retained indefinitely by default.
- Hard delete only in v1 (no soft-delete columns).
- No partial deletion windows (no transcript-only delete mode).
- Conversation failures tracked in a dedicated table.
- Prompt templates are stored in DB.
- Per-segment transcript details stored in JSON within transcript row.
- Per-user daily transcription quota defaults to `3600` seconds and is DB-configurable.

3. Schema is modular by domain:
- identity/device
- upload ticketing and conversation capture
- AI processing artifacts
- quotas and rate limiting
- observability and operations
- compliance lifecycle

4. Every mutating API call is auditable:
- idempotency key
- request/correlation ID
- actor (`user_id`, `device_id`, platform)
- stage transition and failure history

### 5.2 SQL conventions and shared types

Use:

- `uuid` PKs with `gen_random_uuid()`
- `timestamptz` for all time columns
- `created_at` + `updated_at` on mutable tables
- `request_id uuid` + `correlation_id uuid` on pipeline-affecting rows

Recommended enums (or strict check constraints):

- `session_status`: `recording`, `sync_pending`, `uploaded`, `transcribing`, `transcribed`, `summarizing`, `summarized`, `failed`
- `segment_upload_status`: `pending`, `uploaded`, `failed`
- `pipeline_stage`: `issue_upload_ticket`, `finalize`, `transcribe`, `summarize`, `ask`
- `pipeline_status`: `queued`, `running`, `succeeded`, `failed`, `canceled`
- `platform_type`: `watchos`, `ios`, `edge`
- `limit_mode`: `monitor`, `enforce`

### 5.3 Domain tables

### A) Identity and device domain

1. `user_profiles`
- `user_id uuid pk references auth.users(id)`
- `display_name text`
- `timezone text`
- `locale text`
- `created_at timestamptz default now()`
- `updated_at timestamptz default now()`

2. `user_devices`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `device_id text not null` (app-generated stable ID)
- `platform platform_type not null`
- `app_version text`
- `os_version text`
- `last_seen_at timestamptz`
- `created_at timestamptz default now()`
- unique `(user_id, device_id)`

3. `user_consent_events`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `consent_type text not null` (`recording_indicator_ack`, `privacy_policy`, `ai_processing`)
- `consent_version text not null`
- `accepted boolean not null`
- `occurred_at timestamptz not null`
- `request_id uuid`
- `properties jsonb not null default '{}'::jsonb`

4. `idempotency_keys`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `action_key text not null`
- `idempotency_key text not null`
- `request_hash text`
- `first_response jsonb`
- `created_at timestamptz default now()`
- unique `(user_id, action_key, idempotency_key)`

### B) Upload ticketing and capture domain

5. `watch_upload_tickets`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `session_id uuid not null`
- `segment_index int not null`
- `storage_path text not null`
- `signed_upload_url text not null`
- `expires_at timestamptz not null`
- `issued_to_device_id text not null`
- `consumed_at timestamptz`
- `request_id uuid`
- `created_at timestamptz default now()`
- unique `(session_id, segment_index, issued_to_device_id, created_at)`

6. `conversation_sessions`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `source_device_id text`
- `language text not null default 'en' check (language = 'en')`
- `started_at timestamptz not null`
- `ended_at timestamptz`
- `status session_status not null`
- `total_duration_ms int`
- `segment_count int not null default 0`
- `latest_error_code text`
- `latest_error_message text`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`
- `updated_at timestamptz default now()`

7. `conversation_segments`
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `segment_index int not null`
- `storage_path text not null`
- `upload_status segment_upload_status not null default 'pending'`
- `uploaded_from text not null default 'watch'` (`watch`, `phone_fallback`)
- `duration_ms int`
- `bytes bigint`
- `content_sha256 text`
- `started_at timestamptz`
- `ended_at timestamptz`
- `request_id uuid`
- `created_at timestamptz default now()`
- unique `(session_id, segment_index)`

8. `session_sync_attempts`
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `attempt_no int not null`
- `stage text not null` (`ticket_issue`, `watch_upload`, `metadata_upsert`, `finalize`)
- `status text not null` (`started`, `succeeded`, `failed`)
- `error_code text`
- `error_message text`
- `duration_ms int`
- `request_id uuid`
- `created_at timestamptz default now()`

9. `session_stage_transitions` (append-only audit)
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `from_status session_status`
- `to_status session_status not null`
- `reason text`
- `request_id uuid`
- `correlation_id uuid`
- `actor_platform platform_type`
- `occurred_at timestamptz not null default now()`

10. `conversation_failures` (required structured failure log)
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `stage pipeline_stage not null`
- `error_code text not null`
- `error_message text`
- `is_retryable boolean not null default true`
- `retry_after_seconds int`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`

### C) AI processing domain

11. `prompt_templates`
- `id uuid pk`
- `name text not null`
- `version int not null`
- `kind text not null` (`summary`, `qa`)
- `template_text text not null`
- `is_active boolean not null default true`
- `created_at timestamptz default now()`
- unique `(name, version)`

12. `conversation_transcripts`
- `id uuid pk`
- `session_id uuid unique not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `transcript_text text not null`
- `segments_json jsonb not null default '[]'::jsonb`
- `language text not null default 'en' check (language = 'en')`
- `model text`
- `audio_seconds numeric(10,2)`
- `tokens_in int`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`

13. `conversation_summaries`
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `summary_prompt_name text not null`
- `summary_prompt_version int not null`
- `summary_text text not null`
- `model text`
- `tokens_in int`
- `tokens_out int`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`
- unique `(session_id, summary_prompt_name, summary_prompt_version)`

14. `conversation_notes`
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `note_text text not null`
- `version int not null default 1`
- `request_id uuid`
- `created_at timestamptz default now()`
- `updated_at timestamptz default now()`
- unique `(session_id, user_id)`

15. `conversation_questions`
- `id uuid pk`
- `session_id uuid not null references conversation_sessions(id) on delete cascade`
- `user_id uuid not null references auth.users(id)`
- `question text not null`
- `answer text`
- `status text not null default 'pending'` (`pending`, `answered`, `failed`)
- `model text`
- `tokens_in int`
- `tokens_out int`
- `latency_ms int`
- `error_code text`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`
- `answered_at timestamptz`

16. `ai_model_calls` (cost and latency visibility)
- `id uuid pk`
- `user_id uuid references auth.users(id)`
- `session_id uuid references conversation_sessions(id)`
- `question_id uuid references conversation_questions(id)`
- `stage pipeline_stage not null`
- `provider text not null default 'openai'`
- `model text not null`
- `prompt_template_name text`
- `prompt_template_version int`
- `tokens_in int`
- `tokens_out int`
- `audio_seconds numeric(10,2)`
- `latency_ms int`
- `estimated_cost_usd numeric(10,6)`
- `request_id uuid`
- `correlation_id uuid`
- `created_at timestamptz default now()`

### D) Quotas and rate-limit domain

17. `user_usage_quotas`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `daily_audio_seconds_limit int not null default 3600`
- `is_enabled boolean not null default true`
- `updated_at timestamptz not null default now()`
- unique `(user_id)`

18. `user_daily_audio_usage`
- `usage_date date not null`
- `user_id uuid not null references auth.users(id)`
- `transcribed_audio_seconds int not null default 0`
- `updated_at timestamptz not null default now()`
- primary key `(usage_date, user_id)`

19. `quota_decisions`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `action_key text not null` (`transcribe_session`)
- `request_id uuid`
- `allowed boolean not null`
- `limit_value int not null`
- `current_value int not null`
- `window_start date not null`
- `decided_at timestamptz not null default now()`

20. `api_usage_counters`
- `id uuid pk`
- `scope_type text not null` (`user`, `device`, `ip`)
- `scope_id text not null`
- `action_key text not null`
- `window_start timestamptz not null`
- `window_seconds int not null`
- `request_count int not null default 0`
- `updated_at timestamptz not null default now()`
- unique `(scope_type, scope_id, action_key, window_start, window_seconds)`

21. `rate_limit_rules`
- `id uuid pk`
- `scope_type text not null`
- `action_key text not null`
- `window_seconds int not null`
- `max_requests int not null`
- `mode limit_mode not null default 'monitor'`
- `is_enabled boolean not null default true`
- `created_at timestamptz default now()`
- unique `(scope_type, action_key, window_seconds)`

22. `rate_limit_decisions`
- `id uuid pk`
- `scope_type text not null`
- `scope_id text not null`
- `action_key text not null`
- `request_id uuid`
- `allowed boolean not null`
- `rule_id uuid references rate_limit_rules(id)`
- `mode limit_mode not null`
- `current_count int`
- `max_requests int`
- `retry_after_seconds int`
- `decided_at timestamptz not null default now()`

23. `cost_budget_rules`
- `id uuid pk`
- `scope_type text not null` (`global`, `user`)
- `scope_id text not null`
- `period text not null default 'weekly'`
- `cap_usd numeric(10,2) not null`
- `is_enabled boolean not null default true`
- `created_at timestamptz default now()`

Seed recommendation:
- one initial global weekly cap row with `cap_usd=250.00`

24. `cost_budget_windows`
- `id uuid pk`
- `scope_type text not null`
- `scope_id text not null`
- `window_start date not null`
- `window_end date not null`
- `spent_usd numeric(10,6) not null default 0`
- `updated_at timestamptz not null default now()`
- unique `(scope_type, scope_id, window_start, window_end)`

25. `cost_budget_alerts`
- `id uuid pk`
- `rule_id uuid not null references cost_budget_rules(id)`
- `window_id uuid not null references cost_budget_windows(id)`
- `threshold_percent int not null`
- `triggered_at timestamptz not null default now()`

### E) Observability and operations domain

26. `app_events` (high-volume immutable stream)
- `id uuid pk`
- `event_id text` (client-generated ID for dedupe)
- `user_id uuid references auth.users(id)` (nullable pre-auth)
- `device_id text not null`
- `platform platform_type not null`
- `event_name text not null`
- `event_version int not null default 1`
- `app_session_id uuid`
- `conversation_session_id uuid references conversation_sessions(id)`
- `request_id uuid`
- `correlation_id uuid`
- `occurred_at timestamptz not null`
- `received_at timestamptz not null default now()`
- `properties jsonb not null default '{}'::jsonb`
- `app_version text`
- `build_number text`
- `os_version text`
- unique `(platform, event_id)` where `event_id is not null`

27. `event_ingest_batches`
- `id uuid pk`
- `user_id uuid references auth.users(id)`
- `device_id text`
- `request_id uuid`
- `batch_size int not null`
- `accepted_count int not null`
- `rejected_count int not null`
- `first_event_at timestamptz`
- `last_event_at timestamptz`
- `created_at timestamptz default now()`

28. `function_invocations`
- `id uuid pk`
- `function_name text not null`
- `user_id uuid references auth.users(id)`
- `request_id uuid`
- `correlation_id uuid`
- `status_code int`
- `duration_ms int`
- `result text not null` (`ok`, `error`)
- `error_code text`
- `error_message text`
- `created_at timestamptz default now()`

29. `daily_usage_rollups`
- `usage_date date not null`
- `user_id uuid not null references auth.users(id)`
- `app_opens int not null default 0`
- `recording_starts int not null default 0`
- `recording_stops int not null default 0`
- `sessions_finalized int not null default 0`
- `transcriptions_completed int not null default 0`
- `summaries_completed int not null default 0`
- `questions_asked int not null default 0`
- `created_at timestamptz default now()`
- primary key `(usage_date, user_id)`

### F) Compliance and lifecycle domain

30. `data_deletion_requests`
- `id uuid pk`
- `user_id uuid not null references auth.users(id)`
- `status text not null` (`requested`, `running`, `completed`, `failed`)
- `requested_at timestamptz not null default now()`
- `completed_at timestamptz`
- `request_id uuid`
- `error_code text`
- `error_message text`

Note:
- Supabase Auth has `auth.audit_log_entries`; keep auth-level auditing there and product-level auditing in the tables above.
- `data_deletion_requests` is admin/legal only in v1 (no user-facing self-serve delete flow).

### 5.4 RLS model

### User-owned tables

Policy pattern:

- `SELECT`: `auth.uid() = user_id`
- `INSERT`: `auth.uid() = user_id`
- `UPDATE`: `auth.uid() = user_id`
- `DELETE`: `auth.uid() = user_id`

Applies to:

- `user_profiles`
- `user_devices`
- `user_consent_events`
- `conversation_sessions`
- `conversation_segments`
- `conversation_summaries`
- `conversation_transcripts`
- `conversation_notes`
- `conversation_questions`
- `conversation_failures` (read for user-facing troubleshooting)
- `session_sync_attempts`
- `session_stage_transitions`
- `daily_usage_rollups`

### System-operated tables

Restrict direct client access; service role only for writes (and usually reads):

- `idempotency_keys`
- `watch_upload_tickets`
- `ai_model_calls`
- `user_usage_quotas`
- `user_daily_audio_usage`
- `quota_decisions`
- `api_usage_counters`
- `rate_limit_rules`
- `rate_limit_decisions`
- `event_ingest_batches`
- `function_invocations`
- `cost_budget_rules`
- `cost_budget_windows`
- `cost_budget_alerts`
- `data_deletion_requests`

### Derived views

Expose client-safe projections through views or RPCs:

- `session_list_view`
- `session_detail_view`
- `question_history_view`

### 5.5 Indexing, partitioning, and performance

High-priority indexes:

- `conversation_sessions (user_id, started_at desc)`
- `conversation_sessions (user_id, status, updated_at desc)`
- `conversation_segments (session_id, segment_index)`
- `conversation_transcripts (session_id)`
- `conversation_summaries (session_id, created_at desc)`
- `conversation_questions (session_id, created_at desc)`
- `conversation_failures (session_id, created_at desc)`
- `quota_decisions (user_id, decided_at desc)`
- `rate_limit_decisions (scope_type, scope_id, decided_at desc)`
- `app_events (user_id, occurred_at desc)`
- `app_events (event_name, occurred_at desc)`
- `app_events (request_id)`

Partitioning recommendation:

- partition `app_events` monthly on `received_at`
- optional partition `function_invocations` monthly

### 5.6 Retention and cleanup policy

Default retention plan:

- raw audio objects: `30 days`
- transcripts/summaries/questions/notes: indefinite
- `app_events`: 90 days raw
- `event_ingest_batches`: 30 days
- `function_invocations`: 30 to 90 days
- `rate_limit_decisions`: 90 days
- `daily_usage_rollups`: long-term

Deletion semantics:

- hard delete only in v1
- deleting a session cascades to transcript/summaries/questions/notes/segments/failures rows
- no soft-delete fields and no partial artifact delete modes

Automate cleanup with Supabase `pg_cron` jobs and cleanup functions.

## 6) Storage layout (Supabase Storage, private by default)

Primary bucket:

- `conversation-audio` (`private`)

Object path convention:

- `u/{user_id}/s/{session_id}/segments/{segment_index}.m4a`
- `u/{user_id}/s/{session_id}/manifests/{timestamp}.json`

Direct watch upload model:

- iPhone-authenticated flow mints short-lived signed upload tickets
- watch uploads directly to signed URL
- ticket records are persisted in `watch_upload_tickets` for audit/reconciliation

Why this convention:

- owner scoping explicit in prefix
- deterministic lookup for retries and reconciliation
- easy per-session cleanup
- immutable object names avoid overwrite collisions

Storage policy model:

- deny by default
- allow object access only when user folder segment matches `auth.uid()`
- watch direct uploads are allowed only through short-lived signed upload tickets issued by authenticated edge calls
- avoid `upsert` in normal flow; write immutable objects
- use resumable uploads for larger files

### 6.1 Storage-object ownership policy pattern

Design target:

- `bucket_id = 'conversation-audio'`
- first path folder = `u`
- second path folder = `auth.uid()::text`

### 6.2 Migration and compatibility rules

1. Additive first:
- add new columns/tables with defaults
- avoid destructive renames and drops for client-consumed fields

2. Version everything:
- event payloads
- prompt templates
- API contracts

3. Backfill safely:
- use checkpointed migration jobs
- write migration audit rows
