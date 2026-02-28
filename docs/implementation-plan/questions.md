# 10) Open Questions and Decision Log

Last updated: `2026-02-26`

## Resolved decisions (already enforced in plan)

1. Language scope: English-only in v1.
2. Recording UX: no extra onboarding consent screen in v1; active recording indicator is mandatory.
3. Upload model: watch uploads directly with short-lived tickets issued under iPhone-authenticated context.
4. Data lifecycle: raw audio short retention (`30 days` default); transcript/summary/Q&A/notes long-term retention.
5. Deletion model: hard delete only in v1.
6. Notes and Q&A context: transcript + latest summary + user notes.
7. Summary flow: summarize automatically after transcription.
8. Summary failure handling: session transitions to `failed`.
9. Device policy: multi-phone support is in scope for v1.
10. Quota baseline: per-user daily transcription quota defaults to `3600` seconds and is DB-configurable.
11. Rate-limits: monitor mode runs in all environments before selective enforcement.

## Remaining open questions

## A) Must resolve before beta launch

1. Jurisdiction policy:
- Which recording-consent jurisdictions are in launch scope (for example US-only vs global)?

2. Session size limits:
- Maximum allowed segment duration and total session duration for v1.

3. Hard-delete SLA:
- Target completion window for admin/legal hard-deletion requests (for example 24h, 72h, 7 days).

4. Prompt bundle:
- Exact launch prompt variants beyond `say_prompt_default` (for example `say_prompt_action_items`).

5. Budget approvals:
- Confirm starting weekly global AI spend cap (currently seeded to `$250/week`) and escalation path.

## B) Resolve during foundation phase

1. Retry constants:
- Exact retry counts and backoff windows per stage (`upload`, `finalize`, `transcribe`, `summarize`, `ask`).

2. Rate-limit thresholds:
- Initial monitor thresholds per action and scope (`user`, `device`, `ip`) before enforcement starts.

3. Auth provider policy:
- Keep Apple-only for v1, or allow additional providers at launch.

4. Operational ownership:
- Named owner and review cadence for dashboards, alerts, and weekly threshold tuning.

## C) Post-v1 candidates

1. Watch-native auth/session model (deferred).
2. Shared sessions/collaboration.
3. Multi-language capture and summary.
4. User-facing export and delete workflows.
