# AppleWatchRecorder

Apple Watch + iPhone conversation-capture app that records audio, uploads it, and transcribes sessions in the cloud.

## Overview
The Watch app records audio (with an analog recording indicator) and hands sessions to the paired iPhone app over WatchConnectivity, with a local queue for offline capture. The iPhone app manages auth, lists and details sessions, and lets the user review notes and ask questions about a recording. A Supabase backend issues upload tickets, transcribes audio via OpenAI, cleans up stored audio, and enforces cost budgets and health snapshots.

## Tech
Swift / SwiftUI (watchOS + iOS, shared domain layer, XCTest suites), Xcode workspace. Backend on Supabase: Postgres migrations, scheduled cron jobs, and Deno edge functions (transcribe-session, create-upload-ticket, cleanup-audio, health-snapshot, evaluate-cost-budgets) integrating OpenAI.

## Getting started
Open `apps/AppleWatchRecorder/AppleWatchRecorder.xcworkspace` in Xcode. Supabase functions live under `supabase/functions`. Detailed design docs are in `docs/implementation-plan/`.

## Status
In-development implementation following the plan in `docs/implementation-plan/`; client apps, edge functions, and schema are present.
