# Runbook

## Environment

- Supabase project:
  - URL: `https://blxswxdnrybnponwbgte.supabase.co`
  - edge base URL: `https://blxswxdnrybnponwbgte.supabase.co/functions/v1`
  - storage bucket: `conversation-audio`
- iPhone app Info.plist already contains:
  - `SUPABASE_URL`
  - `SUPABASE_PUBLISHABLE_KEY`
  - `EDGE_FUNCTION_BASE_URL`
  - `AUTH_REDIRECT_URL=applewatchrecorder://auth-callback`
- Supabase Vault secrets currently expected by Edge Functions:
  - `internal_job_secret`
  - `openai_api_key`
- `internal_job_secret` is already present in Vault.
- `openai_api_key` is optional for first-run testing because the pipeline now falls back to placeholder transcript, summary, and Q&A output when the key is absent.

## Manual Setup Left

1. Enable email auth in Supabase Auth.
   - Supabase docs: [Passwordless email logins](https://supabase.com/docs/guides/auth/auth-email-passwordless)
   - Hosted projects already have email auth enabled by default, but the app now expects a typed OTP code instead of a magic link.
2. Update the Supabase `Magic Link` email template so it sends `{{ .Token }}` instead of `{{ .ConfirmationURL }}`.
   - Supabase docs: [Email Templates](https://supabase.com/docs/guides/auth/auth-email-templates)
   - Minimal template:
     ```html
     <h2>Your Watch Recorder code</h2>
     <p>Enter this code in the app: {{ .Token }}</p>
     ```
3. Optional: tune `Auth > Providers > Email > Email OTP Expiration` if you want the code validity window changed from the default.
4. Optional: add `openai_api_key` to Supabase Vault to replace placeholder AI output with real transcription, summaries, and answers.

## Deploy Order

1. Apply the initial SQL migrations.
2. Reload the PostgREST schema cache after migrations that add or replace views.
   - SQL: `notify pgrst, 'reload schema';`
3. Run `seed.sql`.
4. Deploy Edge Functions.
5. Build the iPhone target.
6. Build the watch target after watchOS simulator/device support is installed.
7. Test the paired iPhone/watch flow.

Current deployed Edge Functions:

- `ingest-events`
- `update-session-notes`
- `create-upload-ticket`
- `finalize-session`
- `transcribe-session`
- `summarize-session`
- `ask-session`
- `cleanup-audio`
- `evaluate-cost-budgets`

## Scheduled Jobs

- `cleanup-audio`
  - run daily at 02:00
  - deletes raw audio objects older than 30 days
- `evaluate-cost-budgets`
  - run hourly
  - upserts weekly spend windows and inserts 50/80/100 percent alerts

## Operational Checks

- Review function invocation error rates weekly.
- Review `rate_limit_decisions` and `quota_decisions` before enabling hard enforcement on additional actions.
- Review `ai_model_calls` weekly against the `$50` budget cap.

## Local Validation

- iPhone build:
  - `xcodebuild -project apps/AppleWatchRecorder/AppleWatchRecorder.xcodeproj -scheme AppleWatchRecorder -configuration Debug -destination 'generic/platform=iOS Simulator' -packageCachePath .swiftpm-cache-20260228 -clonedSourcePackagesDirPath .spm-clean-20260228 build`
- iPhone tests:
  - `xcodebuild -project apps/AppleWatchRecorder/AppleWatchRecorder.xcodeproj -scheme AppleWatchRecorder -configuration Debug -destination 'platform=iOS Simulator,id=98A00D2D-F3E5-47EF-9DEA-1FFBD9138FB4' -packageCachePath .swiftpm-cache-20260228 -clonedSourcePackagesDirPath .spm-clean-20260228 test`
- Latest passing test result bundle:
  - `/Users/caden/Library/Developer/Xcode/DerivedData/AppleWatchRecorder-duudsspvvcntqiccjhxqisvmyibg/Logs/Test/Test-AppleWatchRecorder-2026.02.27_23-40-12--0600.xcresult`
