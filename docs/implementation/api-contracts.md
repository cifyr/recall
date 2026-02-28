# API Contracts

## Public Functions

- `POST /functions/v1/create-upload-ticket`
  - caller: iPhone
  - request: `session_id`, `segment_index`, `content_type`
  - response: `session_id`, `segment_index`, `storage_path`, `signed_upload_url`, `expires_at`
- `POST /functions/v1/finalize-session`
  - caller: iPhone
  - request: `session_id`, `finalize_reason`
  - response: `session_id`, `status`, `pipeline.transcription_enqueued`
- `POST /functions/v1/update-session-notes`
  - caller: iPhone
  - request: `session_id`, `notes`
  - response: `session_id`, `notes_updated`
- `POST /functions/v1/ask-session`
  - caller: iPhone
  - request: `session_id`, `question`, `include_user_notes`
  - response: `question_id`, `session_id`, `answer`, `model`
- `POST /functions/v1/ingest-events`
  - caller: iPhone
  - request: `events[]`
  - response: `accepted`, `rejected`, `errors[]`

## Internal Functions

- `POST /functions/v1/transcribe-session`
- `POST /functions/v1/summarize-session`
- `POST /functions/v1/cleanup-audio`
- `POST /functions/v1/evaluate-cost-budgets`

## Direct PostgREST Reads

- `GET /rest/v1/session_feed_view`
- `GET /rest/v1/session_detail_view`
- `GET /rest/v1/question_history_view`

## Direct PostgREST Writes

- `POST /rest/v1/user_devices`
- `POST /rest/v1/conversation_sessions`
- `POST /rest/v1/conversation_segments`
