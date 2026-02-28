# 06) API Contracts

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 13) Contract-First API specification (Supabase-first)

This project uses Supabase for:
- Auth (`auth.users`, JWT session tokens)
- Database (Postgres with RLS)
- Storage (private `conversation-audio` bucket)
- Server endpoints (Edge Functions)

The API layer is the boundary between apps (watch/iPhone) and backend orchestration.
All behavior below should be finalized before coding starts.

### 13.1 End-goal definition before implementation

V1 backend goal:
- A signed-in user can record on watch, upload segments directly via iPhone-issued tickets, finalize a session, receive transcript/summary, and ask follow-up questions.
- Every meaningful action is observable (events + logs + request correlation).
- Every mutating endpoint is safe to retry (idempotent by contract).
- Every user-owned read/write is protected by Supabase Auth + RLS.

V1 non-goals:
- Multi-user shared sessions
- Real-time collaborative editing on transcripts
- Watch direct JWT auth/session management in v1

### 13.2 Cross-cutting contract rules

#### Auth and authorization
- Client-facing functions use `verify_jwt = true`.
- Every request includes `Authorization: Bearer <supabase_access_token>`.
- Function code resolves `auth.uid()` from JWT and treats it as authoritative actor identity.
- Service-role keys are never embedded in watch/iPhone apps.

#### Required request headers
- `Authorization`: Supabase JWT.
- `X-Request-Id`: UUID generated per request attempt.
- `X-Device-Id`: stable app-scoped device identifier.
- `X-Platform`: `watchos` | `ios` | `edge`.
- `X-App-Version`: semantic app version.
- `X-Build-Number`: build number.
- `X-Contract-Version`: starts at `2026-02-v1`.

Optional:
- `X-Idempotency-Key`: required for endpoints marked idempotent-critical below.
- `X-Client-Timestamp`: ISO8601 client clock for drift debugging.
- `x-region`: explicit Edge Function region when needed.

#### Standard success envelope
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

#### Standard error envelope
```json
{
  "ok": false,
  "error": {
    "code": "rate_limit_exceeded",
    "message": "Too many requests for ask_session",
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

#### Status code policy
- `200`: success (including idempotent replay).
- `202`: accepted async work.
- `400`: invalid request shape.
- `401`: missing/invalid JWT.
- `403`: authenticated but not authorized for resource.
- `404`: resource not found (or hidden by ownership rules).
- `409`: state conflict (for example finalize before any segments are available).
- `413`: payload too large.
- `422`: semantically invalid input.
- `429`: rate limited (`Retry-After` header required).
- `500`: unhandled server error.
- `503`: dependency unavailable (DB/OpenAI/transient platform issue).

#### Idempotency policy
- Idempotent-critical endpoints: `ingest-events`, `create-upload-ticket`, `finalize-session`, `ask-session`.
- Idempotency scope: `(user_id, endpoint, idempotency_key)` for 24h default window.
- Fallback dedupe keys:
  - events: client-generated event UUID (`app_events.event_id`)
  - segments: unique `(session_id, segment_index)`
  - summaries: unique `(session_id, summary_prompt_name, summary_prompt_version)`
- Repeat submissions return same semantic outcome, never duplicate side effects.

### 13.3 Endpoint inventory

| Method | Endpoint | Caller | Purpose |
|---|---|---|---|
| POST | `/functions/v1/ingest-events` | watch + iPhone | Bulk event ingestion for analytics/observability |
| POST | `/functions/v1/create-upload-ticket` | iPhone | Issue short-lived signed upload ticket for watch direct storage upload |
| POST | `/functions/v1/finalize-session` | iPhone | Seal session and trigger transcript pipeline |
| POST | `/functions/v1/transcribe-session` | edge/internal | Produce transcript from uploaded segments |
| POST | `/functions/v1/summarize-session` | edge/internal | Produce one or more summary variants |
| POST | `/functions/v1/ask-session` | iPhone | Session-scoped Q&A over transcript + summaries |
| POST | `/functions/v1/update-session-notes` | iPhone | Upsert user notes for session detail and Q&A context |
| GET | `/rest/v1/session_feed_view` | iPhone | Session list hydration (read model view) |
| GET | `/rest/v1/session_detail_view` | iPhone | Session detail hydration (joined read model) |

### 13.4 Endpoint contracts

#### POST `/functions/v1/ingest-events`

Purpose:
- Ingest structured app/system events with strict validation.

Request body:
```json
{
  "events": [
    {
      "event_id": "uuid",
      "event_name": "watch_recording_started",
      "event_version": 1,
      "occurred_at": "2026-02-26T00:00:00Z",
      "app_session_id": "uuid",
      "conversation_session_id": "uuid",
      "properties": {
        "recording_mode": "tap_toggle"
      }
    }
  ]
}
```

Rules:
- Max batch size: 200 events.
- Max body size: 256 KB.
- Unknown `event_name` rejected per-item, not whole batch.
- `properties` must be JSON object, no top-level arrays.

Response:
```json
{
  "ok": true,
  "data": {
    "accepted": 180,
    "rejected": 2,
    "errors": [
      {
        "event_id": "uuid",
        "code": "invalid_event_name"
      }
    ]
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Side effects:
- Bulk insert into `app_events`.
- Optional async update to `daily_usage_rollups`.

Error codes:
- `invalid_payload`
- `batch_too_large`
- `event_schema_violation`
- `rate_limit_exceeded`

#### POST `/functions/v1/create-upload-ticket`

Purpose:
- Create a short-lived signed upload ticket so watch can upload segment audio directly to Supabase Storage.

Request body:
```json
{
  "session_id": "uuid",
  "segment_index": 3,
  "content_type": "audio/m4a"
}
```

Rules:
- Caller must own session.
- Response is idempotent by `(session_id, segment_index, idempotency_key)` while ticket is valid.
- Ticket TTL should be short (recommended: 5-10 minutes).

Response:
```json
{
  "ok": true,
  "data": {
    "session_id": "uuid",
    "segment_index": 3,
    "storage_path": "u/<user_id>/s/<session_id>/segments/3.m4a",
    "signed_upload_url": "https://...",
    "expires_at": "2026-02-26T00:10:00Z"
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Error codes:
- `session_not_found`
- `session_not_owned`
- `invalid_segment_index`
- `ticket_issue_failed`

#### POST `/functions/v1/finalize-session`

Purpose:
- Mark a recording session complete and start transcript workflow.

Request body:
```json
{
  "session_id": "uuid",
  "finalize_reason": "user_long_press"
}
```

Rules:
- Caller must own session.
- Session must not already be terminal `failed` unless retry flag is explicit.
- If already `uploaded|transcribing|transcribed|summarized`, return idempotent success.

Response:
```json
{
  "ok": true,
  "data": {
    "session_id": "uuid",
    "status": "uploaded",
    "pipeline": {
      "transcription_enqueued": true
    }
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Side effects:
- Validates segment availability.
- Updates `conversation_sessions.status`.
- Emits `session_finalize_requested|session_finalize_succeeded|session_finalize_failed` events.
- Triggers `transcribe-session` via direct Edge invoke in v1.

Error codes:
- `session_not_found`
- `session_not_owned`
- `session_not_ready`
- `invalid_state_transition`
- `rate_limit_exceeded`

#### POST `/functions/v1/transcribe-session` (internal)

Purpose:
- Build transcript from uploaded audio segments.

Request body:
```json
{
  "session_id": "uuid",
  "transcription_model": "auto_lowest_cost"
}
```

Rules:
- Internal invocation only (service context or signed internal flow).
- Must be idempotent: rerun replaces/updates same transcript row for same session.
- Handles partial failures by marking session `failed` with error metadata.
- Enforces per-user daily audio quota from `user_usage_quotas` (default `3600` seconds/day).
- Language is fixed to English (`en`) in v1.
- Model selection uses the lowest-cost configured transcription profile (default fallback: `whisper-1`).

Response:
```json
{
  "ok": true,
  "data": {
    "session_id": "uuid",
    "status": "transcribed",
    "transcript_id": "uuid",
    "tokens_in": 1234
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Side effects:
- Writes `conversation_transcripts`.
- Updates session state to `transcribed`.
- Emits `transcription_requested|succeeded|failed`.
- Triggers `summarize-session` on success.

Error codes:
- `audio_not_found`
- `transcription_upstream_error`
- `resource_limit_exceeded`

#### POST `/functions/v1/summarize-session` (internal)

Purpose:
- Generate one summary variant from transcript.

Request body:
```json
{
  "session_id": "uuid",
  "summary_prompt_name": "say_prompt_default",
  "summary_prompt_version": 1,
  "summary_model": "gpt-4o-mini"
}
```

Rules:
- Unique output by `(session_id, summary_prompt_name, summary_prompt_version)`.
- Prompt templates are server-side only; client cannot send raw prompt text in v1.
- Session transitions through `transcribed -> summarizing -> summarized` on success.
- On failure, session transitions to `failed` and a `conversation_failures` row is written.

Response:
```json
{
  "ok": true,
  "data": {
    "session_id": "uuid",
    "status": "summarized",
    "summary_id": "uuid",
    "summary_prompt_name": "say_prompt_default",
    "summary_prompt_version": 1
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Error codes:
- `transcript_missing`
- `prompt_template_missing`
- `summary_upstream_error`

#### POST `/functions/v1/ask-session`

Purpose:
- Answer a user question scoped to a single conversation session.

Request body:
```json
{
  "session_id": "uuid",
  "question": "What follow-ups did we agree on?",
  "answer_style": "concise",
  "include_user_notes": true
}
```

Rules:
- Caller must own session.
- Question max length: 2,000 chars.
- Include fallback answer when not grounded in transcript context.
- Q&A context includes transcript + latest summary + user notes when enabled.

Response:
```json
{
  "ok": true,
  "data": {
    "question_id": "uuid",
    "session_id": "uuid",
    "answer": "You agreed to send the draft by Friday.",
    "model": "gpt-4o-mini"
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Side effects:
- Writes `conversation_questions` row.
- Emits `question_asked|question_answered|question_failed`.
- Writes one `rate_limit_decisions` row per request.

Error codes:
- `session_not_found`
- `session_not_owned`
- `question_too_long`
- `rate_limit_exceeded`
- `qa_upstream_error`

#### POST `/functions/v1/update-session-notes`

Purpose:
- Upsert session-level user notes used by iPhone UI and Q&A context assembly.

Request body:
```json
{
  "session_id": "uuid",
  "notes": "Follow up with budget numbers next week."
}
```

Rules:
- Caller must own session.
- Notes max length: 10,000 chars.
- Last-write-wins on `conversation_notes.updated_at`.

Response:
```json
{
  "ok": true,
  "data": {
    "session_id": "uuid",
    "notes_updated": true
  },
  "meta": {
    "request_id": "uuid"
  }
}
```

Error codes:
- `session_not_found`
- `session_not_owned`
- `notes_too_long`
- `invalid_payload`

#### GET `/rest/v1/session_feed_view`

Purpose:
- Efficient list hydration with denormalized session summary state.

Required columns:
- `session_id`
- `started_at`
- `ended_at`
- `status`
- `segment_count`
- `user_notes`
- `latest_summary_excerpt`
- `question_count`

Rules:
- View must run with `security_invoker = true` (or equivalent access control posture) so RLS is preserved.
- Pagination: cursor or `limit/offset` with stable ordering by `started_at desc`.

#### GET `/rest/v1/session_detail_view`

Purpose:
- Session detail hydration with transcript, summaries, and Q&A timeline.

Rules:
- Read-only view, user-scoped through underlying table RLS.
- Include version fields (`event_version`, `prompt_name`) for auditability.
- Include `user_notes` for immediate edit/hydration in session detail screen.

### 13.5 Shared server module layout (modular-by-default)

Recommended structure:

```text
supabase/functions/
  _shared/
    auth.ts               # JWT context extraction + ownership helpers
    request.ts            # header parsing, request_id/idempotency parsing
    response.ts           # standard success/error envelopes
    errors.ts             # typed error catalog -> HTTP mapping
    validation.ts         # zod/valibot schemas for all payloads
    telemetry.ts          # structured logging + event emit helpers
    upload-ticket.ts      # signed upload ticket generation helpers
    rate_limit.ts         # check + persist decisions
    db.ts                 # typed query helpers and transaction wrappers
    openai.ts             # upstream client + retry/backoff wrapper
  create-upload-ticket/index.ts
  ingest-events/index.ts
  finalize-session/index.ts
  transcribe-session/index.ts
  summarize-session/index.ts
  ask-session/index.ts
  update-session-notes/index.ts
```

Contract rule:
- Endpoint handlers may orchestrate modules but should not contain business logic directly.
- New features should reuse `_shared` utilities and add new modules, not duplicate logic.

### 13.6 Versioning and compatibility

- Contract version header: `X-Contract-Version`.
- Event schema version: `event_version` on every event row.
- Prompt schema version: include prompt name/version in summary outputs.
- Breaking changes policy:
  - introduce `v2` endpoint or additive fields first
  - run dual-write/dual-read window
  - remove old shape only after client migration completion

### 13.7 Definition of done for API contract freeze

Before implementation begins:
- JSON schema (or equivalent) exists for every request/response body.
- Error code catalog is complete and referenced by client handling code.
- Idempotency behavior is documented per endpoint.
- Ownership and RLS assumptions are tested in staging.
- Observability fields (`request_id`, user/device/platform) are guaranteed in every endpoint path.
