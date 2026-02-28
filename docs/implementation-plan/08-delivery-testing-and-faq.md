# 08) Delivery, Testing, and FAQ

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 15) Delivery strategy (goal-defined before coding)

### 15.1 Pre-development decision freeze (required)

Before writing production code, finalize these artifacts:
- API contract freeze (`06-api-contracts.md`): endpoints, error codes, idempotency, versioning.
- Observability contract freeze (`07-observability-and-rate-limits.md`): events, logs, metrics, SLOs, alert thresholds.
- Data lifecycle freeze: retention windows, deletion semantics, and legal consent language.
- Environment matrix: local, staging, production Supabase projects and promotion strategy.
- Open questions triage: every unresolved item in `questions.md` assigned owner + due date.

Exit criteria:
- Engineering + product + compliance sign-off on v1 scope and non-goals.
- No P0 unanswered question blocking schema or API implementation.

### 15.2 Phase plan with entry/exit gates

#### Phase 0: Foundations (Supabase + modular backend skeleton)

Build:
- Supabase project setup (Auth, DB, Storage, Edge Functions).
- Base schema + RLS policies + core indexes.
- `_shared` edge modules (auth, validation, response envelope, telemetry, rate-limit helper).
- `ingest-events` endpoint and canonical event constants package.

Exit criteria:
- End-to-end signed request from iPhone -> edge -> DB success.
- Structured logs and events visible in staging dashboards.
- RLS tests pass for all user-owned tables.

#### Phase 1: Capture and sync reliability

Build:
- Watch segment capture state machine.
- Watch direct upload flow using short-lived signed tickets.
- iPhone durable queue + retry/backoff reconciliation.
- deterministic storage path metadata insert + finalize orchestration.

Exit criteria:
- Out-of-order segment deliveries handled correctly.
- Duplicate transfer does not duplicate DB rows or objects.
- Session can be finalized idempotently after retries.

#### Phase 2: Transcript + summary pipeline

Build:
- `finalize-session`, `transcribe-session`, `summarize-session` functions.
- Transcript + summary rendering in iPhone list/detail.
- Pipeline status transitions persisted and observable.

Exit criteria:
- Successful path from finalize to summarized in staging.
- Failure modes mark session `failed` with retry path.
- Latency + success metrics emitted for each stage.

#### Phase 3: Q&A experience

Build:
- `ask-session` function with transcript-grounded answer policy.
- iPhone Q&A UI (history + retries).
- Usage counter updates and per-action telemetry.

Exit criteria:
- Answers persisted with request correlation IDs.
- Rate-limit monitor decisions logged per call.
- Contract tests pass for success and failure envelopes.

#### Phase 4: Hardening and controlled enforcement

Build:
- Incident runbooks + alerts.
- Battery/performance optimization passes.
- Cost cap alerts + quota tuning.
- rate-limit monitor -> selective enforce rollout.

Exit criteria:
- SLO dashboards stable for at least 2 weeks in beta.
- No P0 security/privacy gaps.
- False-positive rate-limit review complete before broad enforcement.

## 16) Testing strategy (multi-layer)

### 16.1 Contract tests (highest priority)

Validate every endpoint against frozen request/response schemas:
- required headers present
- auth failures deterministic
- error envelope format stable
- idempotent replay behavior verified
- response `meta.request_id` always present

### 16.2 Backend tests

Database + RLS:
- user isolation for all user-owned tables
- write attempts with mismatched `user_id` blocked
- view-based reads still respect RLS

Edge functions:
- success path and known failures for each function
- retry safety (same idempotency key or duplicate calls)
- upstream dependency failure handling
- rate-limit decision row written exactly once per request

Pipeline tests:
- missing segment scenario
- partial transcript generation fallback
- summary rerun with same prompt name (upsert/idempotent behavior)

### 16.3 Client tests

Watch app:
- rapid tap start/stop cycles
- long-press finalize from valid/invalid states
- interruption handling (wrist down, app switch, low battery)

iPhone app:
- reconnect after offline periods
- queue durability across app restarts
- duplicate file transfers and metadata dedupe
- list/detail state updates after backend status changes

### 16.4 Non-functional tests

Performance:
- p95 latency checks for `finalize-session` and `ask-session`
- transcript throughput under realistic session sizes

Load and abuse:
- burst traffic to `ingest-events`
- high-frequency Q&A requests to validate rate-limit behavior
- monitor-only vs enforcement behavior comparison

Resilience:
- simulate OpenAI `429` and `5xx`
- simulate storage upload failures and delayed transfers
- verify retries/backoff and dead-letter handling

Compliance:
- indicator-only UX verification (no extra first-launch consent flow)
- recording indicator always visible during active recording
- copy/share actions available for transcript, summary, and Q&A outputs

### 16.5 CI/CD quality gates

Per pull request:
- lint + type-check
- unit tests (client + edge shared modules)
- contract tests for modified endpoints
- SQL migration dry-run on disposable DB

Pre-merge to main:
- integration suite against staging Supabase
- RLS policy regression suite
- smoke test for end-to-end happy path

Pre-release:
- dashboard and alert sanity check
- staged rollout checklist complete
- TestFlight compliance pass

## 17) Developer FAQ (expanded)

Q: Why enforce contract freeze before coding?
A: It avoids churn between watch/iPhone/backend teams and prevents silent drift in payloads, errors, and retry behavior.

Q: Are we committed to Supabase for both auth and DB?
A: Yes for v1. Auth identity (`auth.users`) and all persistent app data live in Supabase.

Q: Why use watch direct upload with iPhone orchestration?
A: It reduces transfer hops and keeps auth centralized. iPhone mints short-lived upload tickets; watch uploads directly; iPhone reconciles state and retries.

Q: Should we call PostgREST directly from clients for writes?
A: Not for core workflows. Use Edge Functions for validated orchestration and richer auditability.

Q: Where should reusable backend logic live?
A: In `supabase/functions/_shared` modules. Endpoint files orchestrate modules and stay thin.

Q: How do we avoid duplicate side effects?
A: Unique constraints, deterministic object paths, idempotency keys, and safe upserts.

Q: What is our source of truth for session state?
A: `conversation_sessions.status` with explicit transitions logged by edge functions.

Q: Can we ship without full dashboards?
A: No. Minimum observability is a release blocker because we need operational certainty before scaling.

Q: How do we handle OpenAI outages or throttling?
A: Catch and classify upstream failures, emit telemetry, retry with backoff where safe, and expose deterministic retryable error codes.

Q: How do we prevent cross-user data access?
A: Supabase Auth JWT + strict RLS on every user-owned table + ownership checks in edge handlers.

Q: Is monitor-only rate limiting necessary?
A: Yes. It gives real usage baselines and reduces false positives before enforcement.

Q: Should analytics include raw transcript content?
A: Default no. Track metadata and outcomes; reserve content logging for tightly controlled debugging.

Q: What is the minimal release candidate for beta?
A: Capture/sync, finalize, transcript, one summary type, Q&A, and observability/rate-limit monitor mode all functioning in staging.

Q: When do we enforce rate limits?
A: Monitor mode runs in all environments from initial rollout; enforcement turns on after baseline review and threshold sign-off.

## 18) Minimal starter checklist (updated)

1. Finalize and sign off `06`, `07`, `08`, and `questions.md`.
2. Create Supabase projects (`local/staging/prod`) and environment variable strategy.
3. Implement base schema, RLS, indexes, and private storage bucket.
4. Scaffold edge function `_shared` modules and standardized response/error helpers.
5. Implement and validate `ingest-events` from watch/iPhone.
6. Build watch capture state machine and iPhone durable sync queue.
7. Implement `finalize-session`, `transcribe-session`, and `summarize-session`.
8. Build session feed/detail read models and iPhone UI integration.
9. Implement `ask-session` and Q&A history.
10. Activate dashboards, SLO alerts, and rate-limit monitor mode.
11. Execute compliance + cost-cap + quota tests before wider rollout.
