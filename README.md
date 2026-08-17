# Recall

Start a recording from your wrist, forget about it, and find the conversation transcribed, summarized, and answerable on your phone.

Recall is a conversation capture system built around the idea that the Apple Watch is the lowest-friction place to start a recording and the worst place to read one. The watch captures. The iPhone owns identity and everything you actually read. Supabase runs the pipeline in between.

## How it fits together

```
Apple Watch          iPhone                Supabase                  OpenAI
-----------          ------                --------                  ------
record segment  ──>  upsert metadata  ──>  create-upload-ticket
     │                                          │
     └── direct upload to Storage <─────────────┘  (short-lived signed ticket)

finalize     ──────> finalize-session ──> transcribe-session ──────>  Whisper
                                              │
                                              └──> summarize-session ─> GPT
                                                        │
read / ask   <────── session detail  <───── ask-session ───────────>  GPT
```

The interesting constraint is that the watch has no authenticated session of its own. Rather than putting user credentials on the wrist, the iPhone authenticates, requests a short-lived signed upload ticket per segment, and hands only that to the watch. The watch uploads audio straight to Storage without ever holding a token that outlives the upload.

Recording is segmented rather than one long file, so a dropped connection or a killed app costs you one segment instead of the conversation. Segments queue locally on the watch when it is out of range and drain over WatchConnectivity when the phone comes back. `finalize-session` is the barrier: it validates what arrived, then kicks off transcription, which chains automatically into summarization. Q&A is scoped to a single session and runs against transcript plus latest summary plus your notes.

The compliance surface is deliberately minimal and physical: the watch face's seconds hand is present exactly when recording is active. There is no hidden recording mode.

## Repository layout

| Path | Contents |
|---|---|
| `apps/AppleWatchRecorder/WatchExtension/` | watchOS capture app — audio recorder, recording indicator, view model |
| `apps/AppleWatchRecorder/iPhoneApp/` | iOS app — auth, session list, session detail, Q&A composer, debug health |
| `apps/AppleWatchRecorder/Shared/` | Domain models and use cases, Supabase services, local queue store, WatchConnectivity brokers |
| `apps/AppleWatchRecorder/Tests/` | XCTest suites for auth coordination, queue records, session decoding, repositories |
| `supabase/functions/` | Deno edge functions plus shared modules |
| `supabase/migrations/` | Schema, RLS, cron jobs, internal invoker, secret RPC |
| `docs/implementation-plan/` | The design documents this was built from |
| `docs/implementation/` | API contracts, event catalog, operational runbook |
| `scripts/` | Xcode project generation and edge function payload builders |

## The backend

Ten edge functions, thin over a shared module layer (`auth`, `db`, `http`, `errors`, `idempotency`, `rate-limit`, `openai`, `prompts`, `secrets`):

`create-upload-ticket` · `finalize-session` · `transcribe-session` · `summarize-session` · `ask-session` · `update-session-notes` · `ingest-events` · `health-snapshot` · `cleanup-audio` · `evaluate-cost-budgets`

Roughly a third of the thirty tables are domain state — sessions, segments, transcripts, summaries, notes, questions. The rest exist because a pipeline that spends money on someone else's API needs to be auditable before it needs to be fast:

- **Idempotency** — `idempotency_keys` makes every workflow function retry-safe, so a client that gives up and retries cannot double-charge a transcription.
- **Traceability** — `session_stage_transitions`, `session_sync_attempts`, and `conversation_failures` record how a session moved and where it stalled, rather than leaving a `failed` status with no story.
- **Quotas and cost** — `user_usage_quotas`, `user_daily_audio_usage`, `quota_decisions`, and the `cost_budget_*` tables enforce a per-user daily audio ceiling (3600 seconds by default, changeable in the database rather than in code) and alert before spend runs away.
- **Rate limiting** — `rate_limit_rules` and `rate_limit_decisions` ship in monitor mode first, so the limits are observed and tuned against real traffic before they start rejecting anything.
- **Prompts** — `prompt_templates` keeps prompt bodies versioned in the database instead of hardcoded in function source.

RLS is enforced on every user-owned table and the audio bucket is private. Raw audio is retained 30 days by default and swept by `cleanup-audio`; transcripts, summaries, notes, and answers are kept.

## Running it

Requires Xcode with watchOS support, the Supabase CLI, and a Supabase project.

1. Apply the migrations in `supabase/migrations/`, then `notify pgrst, 'reload schema';`
2. Run `supabase/seed.sql`
3. Deploy the edge functions
4. Add `internal_job_secret` and `openai_api_key` to Supabase Vault
5. Enable email auth, and change the Magic Link template to send `{{ .Token }}` instead of `{{ .ConfirmationURL }}` — the app expects a typed OTP code, not a link
6. Set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `EDGE_FUNCTION_BASE_URL`, and `AUTH_REDIRECT_URL` in `apps/AppleWatchRecorder/Resources/iPhone-Info.plist`
7. Open `apps/AppleWatchRecorder/AppleWatchRecorder.xcworkspace` and build the iPhone target, then the watch target

Without `openai_api_key` in Vault the pipeline still runs end to end and returns placeholder transcript, summary, and answer content — useful for exercising the plumbing before spending anything.

`docs/implementation/runbook.md` has the full operational detail.

The Supabase anon key in `iPhone-Info.plist` is public by design: it is compiled into any shipped iOS build, and access is enforced by row-level security rather than by keeping the key secret. No service-role key or Vault secret is in this repository.

## Status

Both apps and the full backend pipeline are implemented and run against a live Supabase project. This has not shipped to the App Store, and the design documents in `docs/implementation-plan/` are more thorough than the polish on some of the screens. `questions.md` at the root is the original scoping Q&A, kept as-is because the answers are what locked v1's scope.

## License

MIT — see [LICENSE](LICENSE).
