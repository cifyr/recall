# 03) Edge Functions and Pipeline

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 7) Backend end goal (define before coding)

This section is the build target for backend v1. Do not start implementation until these conditions are accepted.

### 7.1 Definition of done for backend v1

1. Supabase is the single backend system for auth, Postgres, Storage, and Edge Functions.
2. Every authenticated request is mapped to one `auth.users.id` and enforced with RLS.
3. Every important transition writes both:
   - durable state in domain tables (`conversation_sessions`, `conversation_transcripts`, etc.)
   - auditable telemetry in `app_events` and function logs
4. All workflow functions are retry-safe and idempotent.
5. Every function has a stable request/response contract and explicit error codes.
6. Pipeline can recover from partial failures without data corruption.
7. High-cost actions are rate-limit ready from day one (monitor mode enabled in all environments first).

### 7.2 Non-goals for v1

- No direct watch JWT auth session ownership in v1 (watch uploads use short-lived signed tickets issued via iPhone-authenticated flow).
- No multi-tenant org/workspace model.
- No fully automatic background reprocessing loop without explicit retry triggers.

## 8) Modular Edge Function architecture

Use shared modules so each function stays thin and reusable.

### 8.1 Suggested folder layout

```txt
supabase/functions/
  _shared/
    auth.ts
    env.ts
    errors.ts
    request.ts
    response.ts
    logger.ts
    telemetry.ts
    db.ts
    storage.ts
    openai.ts
    upload-ticket.ts
    usage.ts
    rate-limit.ts
    session-state.ts
    types.ts
  create-upload-ticket/index.ts
  finalize-session/index.ts
  transcribe-session/index.ts
  summarize-session/index.ts
  ask-session/index.ts
  update-session-notes/index.ts
  ingest-events/index.ts
```

### 8.2 Shared implementation standards (based on your prior functions)

1. Auth bootstrap:
   - read `Authorization` header case-insensitively
   - pass both `Authorization` and `apikey` headers into `createClient(...)`
   - call `auth.getUser()` and fail with `401` when missing/invalid
2. Strict request validation:
   - parse JSON/form-data safely
   - return `400` on schema errors with machine-readable error codes
3. Structured error handling:
   - consistent JSON response envelope
   - no unhandled throw paths
4. OpenAI response robustness:
   - log raw provider response for debugging
   - parse defensively
   - validate required output fields before DB write
5. Idempotent writes:
   - deterministic upserts or uniqueness constraints for retriable actions
6. Instrument everything:
   - all functions emit start/success/failure telemetry with `request_id`

## 9) Cross-function runtime contract

### 9.1 Required request context

- `Authorization: Bearer <jwt>`
- `X-Request-Id` (client-generated UUID; create server UUID if absent)
- `X-Device-Id` (stable app-scoped device ID)
- `X-Platform` (`ios`, `watchos`, `edge`, optional for internal triggers)
- `X-App-Version` and `X-Build-Number`

### 9.2 Standard response envelope

```json
{
  "ok": true,
  "data": {},
  "meta": {
    "request_id": "uuid",
    "contract_version": "2026-02-v1",
    "server_time": "2026-02-26T00:00:00Z"
  }
}
```

```json
{
  "ok": false,
  "error": {
    "code": "rate_limit_exceeded",
    "message": "Human readable message",
    "retryable": true,
    "details": {
      "retry_after_seconds": 30
    }
  },
  "meta": {
    "request_id": "uuid",
    "contract_version": "2026-02-v1",
    "server_time": "2026-02-26T00:00:00Z"
  }
}
```

### 9.3 Error code baseline

- `unauthorized`
- `forbidden`
- `validation_error`
- `not_found`
- `conflict`
- `rate_limit_exceeded`
- `openai_error`
- `storage_error`
- `db_error`
- `internal_error`

### 9.4 Session state machine

`conversation_sessions.status` transitions:

1. `recording` -> `sync_pending` (capture complete, waiting on upload reconciliation)
2. `sync_pending` -> `uploaded` (finalize successful)
3. `uploaded` -> `transcribing`
4. `transcribing` -> `transcribed`
5. `transcribed` -> `summarizing`
6. `summarizing` -> `summarized`
7. Any in-flight state -> `failed` (with error metadata logged in events)

Invalid transitions must fail with `409 conflict`.

## 10) Edge function specifications

### 10.0 `create-upload-ticket`

Input:
- `session_id`
- `segment_index`
- `file_ext` (default `m4a`)
- `content_type`

Behavior:
1. authenticate via iPhone JWT and verify session ownership
2. build deterministic path: `u/{user_id}/s/{session_id}/segments/{segment_index}.m4a`
3. generate short-lived signed upload URL/token for watch direct upload
4. return upload ticket payload to iPhone for immediate watch handoff
5. emit `segment_upload_ticket_issued`

Notes:
- watch uploads directly to Supabase Storage with signed ticket
- watch never needs persistent Supabase auth session in v1

### 10.1 `finalize-session`

Input:
- `session_id`

Behavior:
1. authenticate caller and verify `session.user_id == auth.uid()`
2. lock session row to prevent duplicate finalize races
3. verify segment rows + storage objects exist (at least one segment)
4. if already `uploaded|transcribing|transcribed|summarizing|summarized`, return idempotent success
5. set `status='uploaded'`, set `ended_at` if missing
6. emit `transcription_requested` event
7. trigger `transcribe-session` using direct Edge Function invoke (chosen for deterministic request lineage in v1)

Telemetry:
- `session_finalize_requested`
- `session_finalize_succeeded`
- `session_finalize_failed`

### 10.2 `transcribe-session`

Input:
- `session_id`

Behavior:
1. authenticate and authorize ownership (or internal trusted trigger)
2. transition `uploaded -> transcribing` atomically
3. enforce per-user daily transcription quota (default `3600` seconds/day, configurable in DB)
4. read ordered segment list from `conversation_segments`
5. fetch private audio objects from Supabase Storage
6. transcribe with bounded concurrency
7. force language to English (`en`) for v1
8. choose transcription model by lowest configured cost profile (default fallback: `whisper-1`)
9. merge transcript text in deterministic segment order
10. write one `conversation_transcripts` row with:
    - merged transcript text
    - `segments_json` payload for per-segment traceability
11. transition `transcribing -> transcribed`
12. emit `transcription_succeeded`
13. trigger `summarize-session`

Implementation notes from prior function:
- keep audio handling defensive (MIME + filename fallback)
- capture OpenAI raw responses for diagnostics
- bound concurrency to control memory and cost
- if one segment fails, mark session failed and include segment index in telemetry

### 10.3 `summarize-session`

Input:
- `session_id`
- `summary_prompt_name` (default `say_prompt_default`)

Behavior:
1. authorize access
2. load transcript by `session_id`
3. load prompt template/version by name
4. call OpenAI Responses API with deterministic parameters
5. parse and validate model output
6. transition `transcribed -> summarizing`
7. upsert `conversation_summaries` on `(session_id, summary_prompt_name, summary_prompt_version)`
8. transition `summarizing -> summarized`
9. emit `summary_succeeded`

Failure behavior:
- if summarization fails, set session state to `failed`
- write `conversation_failures` row with stage=`summarize`
- return deterministic retryable error code where applicable

Model parameters (v1 default):
- `temperature=0.2` for summaries

If summary exists for same prompt/version, return cached result unless `force_regenerate=true`.

### 10.4 `ask-session`

Input:
- `session_id`
- `question`

Behavior:
1. authorize ownership
2. run `check-rate-limit` for `ask_session`
3. load transcript + selected summary + user notes context
4. call OpenAI with transcript-grounded instruction and summary/note augmentation
5. insert `conversation_questions` row with question + answer + model metadata
6. emit `question_answered`

Guarantees:
- never return data from another user
- return explicit `not_found` when session does not exist for caller

Model parameters (v1 default):
- `temperature=0.0` for Q&A

### 10.5 `ingest-events`

Input:
- `{ events: EventInput[] }` from iPhone/watch/edge

Behavior:
1. validate batch size and event schema
2. enforce `event_name` allowlist + `event_version`
3. enrich each event with:
   - authenticated `user_id` when present
   - `received_at` server timestamp
   - normalized platform/app metadata
4. bulk insert into `app_events`
5. reject invalid rows with per-row errors while accepting valid rows
6. optional rollup update (`daily_usage_rollups`)

Idempotency:
- prefer client-provided event UUID in properties to dedupe retries

### 10.6 `update-session-notes`

Input:
- `session_id`
- `notes`

Behavior:
1. authorize ownership
2. validate note size limits
3. upsert `conversation_notes` row for the session
4. emit `session_notes_updated`
5. return updated metadata for immediate client hydration

### 10.7 `check-rate-limit` (shared module + SQL function)

Input:
- `scope_type`, `scope_id`, `action_key`, `request_id`

Behavior:
1. load active rules from `rate_limit_rules`
2. increment/read `api_usage_counters` in one transaction
3. write one decision row to `rate_limit_decisions`
4. return `{ allowed, retry_after_seconds }`

Rollout:
- phase 1: monitor only in all environments (log decisions, do not block)
- phase 2: enforce on `ask-session`, then `transcribe-session`

## 11) Quotas and usage accounting pattern

Adopt the same pattern used in your prior STT function with DB-configurable per-user quotas:

1. Store per-user daily quota in Supabase (`user_usage_quotas`) with default `3600` seconds/day.
2. Read current daily usage (`user_daily_audio_usage`) before expensive provider call.
3. Reject over-limit early with clear `429` response body.
4. On success, upsert usage counters on deterministic key `(usage_date, user_id)`.
5. Log both decision and resulting usage values for auditability.

## 12) Security and secrets baseline

1. All Edge Functions keep `verify_jwt = true`.
2. Service-role key is never shipped to watch or iPhone.
3. OpenAI key exists only in Supabase Edge Function secrets.
4. Storage bucket remains private; access is mediated by authenticated backend logic.
5. Add redaction in logs for tokens, raw auth headers, and PII-heavy transcript fragments.

## 13) Delivery order for backend implementation

1. Build `_shared` auth/request/response/logger modules first.
2. Implement `ingest-events` and prove end-to-end telemetry.
3. Implement `create-upload-ticket` for watch direct uploads.
4. Implement `finalize-session` with idempotent state transition.
5. Implement `transcribe-session` with robust segment handling + quota enforcement.
6. Implement `summarize-session`.
7. Implement `update-session-notes` and `ask-session` with rate-limit check.
8. Enable monitor-mode rate limits in all environments, review data, then enforce selectively.
