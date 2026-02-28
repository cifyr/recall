# 05) AI and Compliance

Split from: `IMPLEMENTATION_BLUEPRINT.md`

## 11) AI model and prompt strategy

### Transcription

- Language: English only in v1 (`en`)
- Model selection: choose lowest-cost approved transcription model via config (default fallback: `whisper-1`)
- No product-level max transcript length in v1; internal chunking is allowed only when needed for runtime limits

### Summaries

- keep prompt templates server-side:
  - `say_prompt_default`
  - `say_prompt_action_items`
  - etc.
- store template name in DB with result
- deterministic generation settings for reliability (`temperature` low, recommended `0.2`)

### Q&A

- constrain answers to transcript scope, augmented by latest summary + user notes field
- optional instruction: if answer not present, say "Not in this conversation"
- deterministic generation settings for reliability (`temperature` low, recommended `0.0`)

## 12) Compliance, privacy, and trust requirements

1. Recording consent + indicator
   - v1 does not add a separate first-launch consent screen.
   - Active recording indicator is mandatory and always visible while recording.
   - Microphone permission prompt is handled by system APIs.

2. Privacy policy
   - Explain what is recorded, where AI processing happens, and retention policy:
   - raw audio retained for 30 days
   - transcript/summary/Q&A retained long-term in v1

3. Data deletion
   - No user-facing deletion flow in v1.
   - If deletion is required for admin/legal reasons, perform hard delete only.

4. Data export
   - No structured export flow in v1.
   - UX supports copy/paste and share actions in iPhone session detail.

5. Encryption and secrets
   - TLS in transit.
   - Supabase secrets only in edge env.
   - No privileged keys on device.

6. Jurisdiction caution
   - Conversation recording consent laws vary by location; require users to obtain legally required participant consent.
