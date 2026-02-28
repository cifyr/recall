# 04) Client Apps and Auth

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 8) Client-side end goal (define before coding)

### 8.1 Definition of done for client v1

1. User can sign in on iPhone with Supabase Auth using passwordless email OTP.
2. Watch can capture multiple audio segments per conversation session.
3. Watch uploads audio segments directly to Supabase Storage using short-lived upload tickets issued by iPhone-authenticated backend calls.
4. iPhone persists a durable sync queue for metadata/state, reconciles uploads, and finalizes sessions.
5. iPhone can display transcript, summaries, and Q&A for each session.
6. iPhone session detail supports copy/share of transcript, summary, and answers.
7. Every important action emits structured telemetry (no silent transitions).
8. All network writes are retry-safe and idempotent.

### 8.2 v1 architecture decision

- Supabase is the only backend identity and data platform.
- iPhone is the backend orchestrator for watch data in v1.
- Watch uploads directly to Supabase Storage using signed upload tickets.
- Watch does not hold long-lived Supabase auth/session tokens in v1.

## 9) iPhone app architecture (source of truth)

### 9.1 Responsibility boundary

The iPhone app owns:
- auth session lifecycle
- upload-ticket issuance for watch direct uploads
- watch metadata intake and reconciliation
- local persistence and retry queue (SQLite wrapper)
- metadata writes and function invocations
- UI state hydration for sessions/transcripts/summaries/questions

### 9.2 Modular code layout (recommended)

```txt
ios-app/
  Features/
    Auth/
    SessionsList/
    SessionDetail/
    AskQuestion/
    SyncStatus/
  Domain/
    Models/
    UseCases/
  Data/
    Supabase/
    LocalStore/
    WatchConnectivity/
  Shared/
    Logging/
    Telemetry/
    Networking/
    Utilities/
```

Implementation rules:
1. Feature modules cannot call Supabase directly.
2. Use cases call repository protocols, not SDK types.
3. Supabase-specific code stays under `Data/Supabase`.

### 9.3 Local queue + sync engine

Queue item shape (local DB):
- `queue_id`
- `session_id`
- `segment_index`
- `storage_path`
- `uploader_mode` (`watch_direct`, `iphone_fallback`)
- `attempt_count`
- `next_attempt_at`
- `last_error_code`
- `created_at`

Sync workflow:
1. watch sends session/segment metadata to iPhone
2. iPhone requests `create-upload-ticket` from backend
3. iPhone returns short-lived ticket to watch
4. watch uploads segment directly to Supabase Storage
5. watch/iPhone reconciliation updates `conversation_segments`
6. when session is finalized and all known segments are uploaded, iPhone calls `finalize-session`
7. iPhone uses hybrid status sync: Realtime subscription + periodic polling fallback

Retry behavior:
- exponential backoff with jitter
- retry on transient network/5xx
- no retry on hard `4xx` validation/auth errors
- if watch direct upload fails repeatedly, allow iPhone relay fallback for that segment

### 9.4 API client boundary

Provide a thin client per backend action:
- `SessionsApi`
- `UploadTicketApi`
- `UploadReconcileApi`
- `FunctionsApi`
- `EventsApi`

Each call must:
- attach `request_id`
- attach auth token
- map backend errors to typed app errors
- emit telemetry before and after call

## 10) Watch app architecture

### 10.1 Recording engine

- Frameworks: `AVFoundation`, `WatchKit`, SwiftUI
- Session config:
  - configure `AVAudioSession` for recording
  - request microphone permission before first use
- Format:
  - AAC (`.m4a`) for size/quality balance

### 10.2 Watch state machine

States:
- `idle`
- `recordingSegment`
- `segmentStopped`
- `finalizingSession`
- `awaitingUploadTicket`
- `uploadingDirect`
- `uploadSucceeded`
- `uploadFailed`

Transitions:
- tap toggles `recordingSegment <-> segmentStopped`
- long press from non-recording state transitions to `finalizingSession`
- iPhone returns signed upload tickets per segment
- watch uploads directly and reports status back to iPhone

### 10.3 Connectivity contract to iPhone

1. `transferUserInfo` for metadata and upload status:
   - `session_id`
   - `segment_index`
   - `started_at`/`ended_at`
   - `duration_ms`
   - `request_id`
2. `sendMessage` for immediate upload-ticket handoff and status acknowledgements when reachable.
3. `transferFile` reserved as fallback transport when direct upload is unavailable.

### 10.4 Runtime constraints

- do not assume indefinite background recording
- treat interruptions as normal states
- persist segment metadata locally before attempting transfer
- use short-lived upload tickets, and refresh them via iPhone when expired

## 11) Auth model across iPhone + watch + Supabase

### 11.1 Recommended v1 auth flow

1. User signs in on iPhone using Supabase Auth email OTP.
2. iPhone stores session tokens securely (Keychain-backed).
3. iPhone performs authenticated backend calls and issues signed upload tickets to watch.
4. Watch uploads directly to Supabase Storage using signed tickets (no long-lived auth tokens on watch).
5. iPhone finalizes sessions and drives processing pipeline calls.

### 11.2 Security constraints

- No service role key in any client app.
- No privileged bypass path for watch uploads; only short-lived signed tickets are accepted.
- Supabase RLS remains the primary data isolation layer.
- Token refresh is handled centrally in iPhone auth module.

### 11.3 v2 option (explicitly deferred)

Watch direct Supabase Auth (JWT on watch) can be evaluated later behind a dedicated module:
- `WatchDirectSyncService`
- isolated token lifecycle manager
- additional connectivity fallback logic

## 12) Event-first client instrumentation

Every state transition emits events through shared telemetry module.

### 12.1 Required watch events

- `watch_recording_started`
- `watch_recording_stopped`
- `watch_session_finalized`
- `segment_upload_ticket_requested`
- `segment_upload_started`
- `segment_upload_succeeded`
- `segment_upload_failed`

### 12.2 Required iPhone events

- `auth_signed_in`
- `auth_signed_out`
- `segment_upload_ticket_issued`
- `segment_upload_reconciled`
- `segment_upload_reconcile_failed`
- `session_finalize_requested`
- `session_finalize_succeeded`
- `session_finalize_failed`
- `session_status_updated`
- `session_notes_updated`
- `question_asked`
- `question_answered`
- `question_failed`

All events must include:
- `request_id`
- `conversation_session_id` (when applicable)
- `device_id`
- `app_version`
- `event_version`

## 13) UI and data-loading contracts

### 13.1 Sessions list

Show:
- start/end timestamps
- processing status
- summary availability
- sync error indicator (if any)

### 13.2 Session detail

Show:
- transcript text
- selected summary view
- editable user notes (included in Q&A context)
- Q&A history
- retry action when failed state exists
- copy/share actions for transcript, summary, and Q&A answers

### 13.3 Consistency behavior

- optimistic UI for local queue actions
- authoritative refresh from Supabase after pipeline transitions
- Realtime subscription for status updates with polling fallback on disconnect
- conflict resolution favors server state

## 14) Reusability and extension guardrails

1. Keep domain models backend-agnostic.
2. Keep feature logic independent from transport SDKs.
3. Version event payloads and backend request contracts.
4. Add new processing stages by composing new use cases, not editing core sync loop.
5. Keep all status transition logic centralized in one state coordinator per app.

## 15) Pre-development checklist (must complete first)

1. Finalize event taxonomy and required properties.
2. Finalize SQLite queue schema and retry policy.
3. Finalize backend error code mapping to client error types.
4. Finalize indicator-only recording UX flow (no extra first-launch consent screen in v1).
5. Finalize initial acceptance tests for watch capture and iPhone sync.
