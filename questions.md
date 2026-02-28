# Implementation Questions (Resolve Before Build)

These are the remaining decisions needed to lock scope and avoid rework.

## Product and compliance

1. Should session capture be single-language only in v1, or must we auto-detect language per session?
only english
2. What is the exact retention policy for raw audio files in Supabase Storage (for example: 30, 90, or 365 days)?
lets keep it short, we dont need it for a while
3. Do we need user-controlled deletion windows (delete transcript only vs delete full session artifacts)?
no, keep transcript, etc forever currently.
4. Should we support export in v1 (JSON/TXT), or defer to v2?
support ocpy and paste, and share.
5. What consent UX is required on first launch beyond the active recording indicator?
nothing is required, the active recording indicator will be if teh seconds hand exists or not.

## Data model and schema

6. Do we want a dedicated `conversation_failures` table for structured retry/debug history, or rely only on `app_events`?
yes
7. Should we add a `prompt_templates` table (name, version, body, active flag) instead of hardcoded prompt names?
yes
8. Do we need a table for per-segment transcript results, or is one merged transcript row enough for v1?
we can use one with json values?
9. Should `conversation_sessions` include `expected_segment_count` to strengthen finalize validation?
no
10. Should we add soft-delete columns (`deleted_at`) to user-owned tables now, or hard delete only?
hard only for v1

## Edge pipeline behavior

11. What is the transcription quota policy (daily minutes per user, and any per-request max)?
unknown
12. Do we require rate limiting for `finalize-session` in v1, or only for `ask-session` and `transcribe-session`?
lets limit at 1 hour/day per user (and make it easy to change). lets store per-user quotas in supabase.
13. Which trigger model is preferred for pipeline chaining: direct function invoke vs DB-webhook-triggered steps?
up to you
14. Should summarize run automatically after every transcription, or only when user first opens session detail?
run automatically so it tanscribes then summarizes. later, they can ask questionsof the transceript.
15. When summarize fails, should session remain `transcribed` with retry option, or move to `failed`?
failed
16. Do we want monitor-only rate limits in production immediately, or in staging first?
all

## OpenAI usage and output contracts

17. Which transcription model is canonical for launch (`gpt-4o-transcribe` vs `whisper-1`)?
whichever is cheaper
18. What maximum transcript length should trigger chunking/splitting before summarization?
no max
19. Should Q&A always use transcript-only context, or transcript + summary depending on token budget?
transcript + summary (and we can let users add their own notes to a field which can also be input)
20. Do we need deterministic temperature settings per endpoint (for example 0.0 for extraction and Q&A)?
up to you

## Client architecture and auth

21. Confirm v1 decision: watch does not authenticate directly to Supabase and never uploads directly.
watch SHOULD upload directly, but auth is through the iPhone app.
22. Should the iPhone app poll for session status updates, subscribe via Realtime, or use a hybrid approach?
up to you, whichever works best
23. Which local queue store is preferred on iPhone (Core Data vs SQLite wrapper)?
up to you, whichever works best
24. Do we need multi-device iPhone session support at launch (same user on multiple phones)?
yes we should
25. Should the watch keep a local history UI, or remain capture-only in v1?
capture only.

## Observability and operations

answer whatever you think is best for these:
26. What are the alert thresholds for pipeline failures (for example: transcription failure rate > 5% over 15 minutes)?
27. Who reviews rate-limit monitor dashboards and how frequently before enforcement is turned on?
28. Do we require PII redaction in logs from day one, and if so what fields are mandatory to redact?
29. What is the target p95 latency for each edge function (`finalize`, `transcribe`, `summarize`, `ask`)?
30. Do we want a weekly cost budget cap and automated alerting for OpenAI spend in v1?
