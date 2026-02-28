# Event Catalog

## Watch Events

- `watch_recording_started`
- `watch_recording_stopped`
- `watch_session_finalized`
- `segment_upload_ticket_requested`
- `segment_upload_started`
- `segment_upload_succeeded`
- `segment_upload_failed`

## iPhone Events

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

## Required Properties

- `request_id`
- `conversation_session_id` when present
- `device_id`
- `platform`
- `app_version`
- `event_version`
