# 07) Observability and Rate Limits

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 14) Observability, analytics, and rate-limit readiness (expanded)

### 14.1 End-goal

Before feature development, define observability as a product requirement:
- We can reconstruct any user flow (record -> sync -> transcript -> summary -> Q&A) from telemetry.
- We can answer "what failed, why, for whom, and how often" within minutes.
- We can enable rate limits safely without re-architecting APIs.
- We can separate client bugs, backend faults, and upstream model/provider failures.

### 14.2 Telemetry architecture (track everything, but intentionally)

Use 4 complementary signals:
- Logs: request-scoped diagnostic detail for engineers.
- Events: analytics-grade product and lifecycle activity (`app_events`).
- Metrics: low-cardinality time-series for dashboards/alerts.
- Traces/correlation: `request_id` stitched across watch, iPhone, edge, and DB writes.

Supabase-specific principle:
- Edge Functions emit structured JSON logs.
- Critical endpoint outcomes are also persisted in DB tables (`app_events`, `rate_limit_decisions`) so telemetry is queryable even if log retention differs.

### 14.3 Structured logging contract (all clients + edge)

Required fields in every log record:
- `timestamp`
- `level` (`debug`,`info`,`warn`,`error`)
- `service` (`watch_app`,`ios_app`,`edge_function`)
- `environment` (`local`,`staging`,`prod`)
- `request_id`
- `trace_id` (if generated separately)
- `user_id` (nullable pre-auth)
- `device_id`
- `action`
- `result` (`ok`,`error`)
- `error_code` (if error)
- `duration_ms` (for timed operations)
- `endpoint` (for networked operations)
- `attempt` (retry count)

Optional but recommended:
- `session_id`
- `segment_index`
- `model`
- `tokens_in`
- `tokens_out`
- `rate_limit_scope`

Redaction rules:
- Never log raw transcript text, question text, or summary text at `info` level.
- Never log raw user notes text.
- If debugging content is unavoidable, log only bounded snippets in controlled environments with explicit redaction markers.
- Never log access tokens, refresh tokens, or signed URLs.
- Hash or redact user email, IP address, and external participant identifiers.

### 14.4 Canonical event catalog (v1)

All event names are constants shared between watch/iPhone/edge.
Each event includes: `event_id`, `event_name`, `event_version`, `occurred_at`, `request_id` when relevant, and `properties`.

#### Auth events
- `auth_signed_in`
- `auth_session_refreshed`
- `auth_signed_out`
- `auth_token_refresh_failed`

#### Watch capture lifecycle
- `watch_recording_started`
- `watch_recording_stopped`
- `watch_segment_saved_local`
- `watch_session_finalized`
- `watch_capture_interrupted`

#### Connectivity and upload lifecycle
- `segment_upload_ticket_requested`
- `segment_upload_ticket_issued`
- `segment_upload_started`
- `segment_upload_succeeded`
- `segment_upload_failed`

#### Backend pipeline lifecycle
- `session_finalize_requested`
- `session_finalize_succeeded`
- `session_finalize_failed`
- `transcription_requested`
- `transcription_succeeded`
- `transcription_failed`
- `summary_requested`
- `summary_succeeded`
- `summary_failed`

#### Q&A lifecycle
- `session_notes_updated`
- `question_asked`
- `question_answered`
- `question_failed`

#### Reliability and control-plane
- `rate_limit_checked`
- `rate_limit_blocked`
- `retry_scheduled`
- `retry_exhausted`
- `dead_letter_enqueued`

#### Compliance and privacy
- `recording_indicator_shown`
- `recording_indicator_hidden`

### 14.5 Event property standards

Base properties required for all events:
- `platform` (`watchos`,`ios`,`edge`)
- `app_version`
- `build_number`
- `os_version`
- `network_type` (if available)

Event-family required properties:
- Recording events: `session_id`, `segment_index`, `duration_ms`.
- Upload events: `storage_path`, `bytes`, `attempt`.
- AI events: `model`, `latency_ms`, `tokens_in`, `tokens_out`, `provider_status`.
- Rate-limit events: `scope_type`, `scope_id_hash`, `action_key`, `allowed`, `current_count`, `max_requests`.

Validation policy:
- `ingest-events` rejects malformed events per-item and returns deterministic error codes.
- Unknown optional properties are allowed if JSON-object typed.
- Breaking changes require incrementing `event_version`.

### 14.6 Metrics catalog and SLOs

Operational metrics:
- ingest acceptance rate
- ingest rejection rate by code
- finalize latency (p50/p95/p99)
- transcription latency + failure rate
- summary latency + failure rate
- Q&A latency + failure rate
- edge status code distribution
- openai upstream error rate (`429`,`5xx`,`timeout`)

Product metrics:
- DAU/WAU/MAU
- sessions per user per day
- median session duration
- segments per session
- transcript completion rate
- summary completion rate
- questions per summarized session

Reliability SLO starter targets:
- `finalize-session` success >= 99.5% (rolling 7d)
- transcript pipeline success >= 98.5% (rolling 7d)
- `ask-session` success >= 99.0% (rolling 7d)
- event ingestion acceptance >= 99.9% excluding client-malformed events

Latency targets:
- `finalize-session` p95 < 1500 ms
- `transcribe-session` p95 < 45 s for a 10-minute audio session
- `summarize-session` p95 < 8 s
- `ask-session` p95 < 10 s

### 14.7 Dashboards (minimum set)

1. Pipeline Health
- finalize -> transcribe -> summarize funnel conversion
- stage latency distributions
- failure breakdown by `error_code`

2. Client Reliability
- watch capture interruptions
- upload-ticket issuance and expiry rates
- direct upload success/failure
- upload retries and exhaustion

3. Product Usage
- active users and session volume
- Q&A adoption and depth
- completion rates by app version

4. Cost and Capacity
- AI token usage per action
- average tokens per session
- projected monthly spend
- weekly spend vs cap (seed default: `$250/week` global)

5. Abuse and Rate Limits
- top actions by request volume
- top heavy users/devices (hashed IDs)
- block rate and false-positive review queue

### 14.8 Alerting policy

Page-worthy alerts:
- transcription failure rate > 5% for 15 minutes
- summarize failure rate > 5% for 15 minutes
- ask-session failure rate > 3% for 15 minutes
- sustained `5xx` above 2% for any critical endpoint

Ticket-level alerts:
- ingestion rejection rate trend increase
- elevated retry exhaustion
- daily rollup lag beyond defined threshold
- rate-limit/quota decision write errors > 1% for 15 minutes

Alert payload must include:
- timeframe
- impacted endpoint/action
- sample error codes
- dashboards/queries for triage

Review ownership and cadence:
- engineering on-call reviews page alerts continuously
- product + backend owners review monitor-mode dashboards weekly before enforcement changes

### 14.9 Rate-limit architecture

#### Core design
- Enforcement source of truth in DB tables:
  - `rate_limit_rules`
  - `api_usage_counters`
  - `rate_limit_decisions`
- Each protected request performs exactly one decision write.
- Action keys are explicit constants (`ingest_events`, `finalize_session`, `ask_session`, `transcribe_session`).

#### Scope evaluation order
1. `user`
2. `device`
3. `ip`

First failing scope blocks request.

#### Decision response shape
When blocked (`429`):
- headers:
  - `Retry-After`
  - `X-RateLimit-Action`
  - `X-RateLimit-Scope`
- body error code: `rate_limit_exceeded`
- include `retry_after_seconds` in error details

#### Rollout stages
- Stage A: monitor-only in all environments (rules `is_enabled=true` with `mode='monitor'`, decisions logged and never blocking)
- Stage B: enforce high-cost actions (`ask_session`, `transcribe_session`)
- Stage C: full action coverage with periodic threshold tuning

#### Tuning inputs
- p95/p99 usage by action and scope
- heavy-user cohort analysis
- false-positive appeal outcomes
- cost-per-action trend

### 14.10 Platform limits and guardrails (research-backed)

As of 2026-02-26, Supabase docs list key Edge Function constraints that must influence implementation:
- max memory: 256 MB
- max wall clock duration: 150s (free) / 400s (paid)
- max CPU time per request: 2s
- max log line length: 10,000 characters
- max log events: 100 events per 10 seconds

Engineering implications:
- keep heavy work split (`finalize` -> `transcribe` -> `summarize`)
- avoid huge payloads in one request
- treat long transcript generation as async pipeline work
- keep logs structured and compact to avoid truncation

Supabase Auth also exposes configurable rate limits (`auth.rate_limit.*`), so auth-flow telemetry must track sign-in, refresh, and verification failures distinctly.

### 14.11 Data retention and compliance

Default retention policy:
- `app_events`: 90 days raw
- `rate_limit_decisions`: 90 days minimum
- `daily_usage_rollups`: long-term
- `conversation-audio` objects: 30 days
- transcript/summary/question/note records: long-term
- high-cardinality debug logs: short TTL, environment dependent

Privacy guardrails:
- avoid storing sensitive raw payloads in analytics tables unless required
- hash IP/device in abuse dashboards where possible
- no user-facing delete/export workflow in v1; only admin/legal hard-delete operations when required

### 14.12 Observability definition of done

Before broad beta:
- All critical endpoints emit structured logs with required fields.
- Event ingestion validates schemas and produces rejection diagnostics.
- Dashboards and alerts are live in staging and production.
- Rate-limit monitor mode is running in all environments from initial rollout.
- Weekly AI budget cap is configured (seed default: `$250/week` global) with automated alerts at 80% and 100%.
- Runbook exists for 429 spikes, upstream model outages, and pipeline stalls.
