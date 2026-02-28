create extension if not exists pgcrypto;
create extension if not exists pg_cron;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'platform_type') then
    create type public.platform_type as enum ('iphone', 'watch', 'edge', 'system');
  end if;
  if not exists (select 1 from pg_type where typname = 'session_status') then
    create type public.session_status as enum (
      'sync_pending',
      'uploaded',
      'transcribing',
      'transcribed',
      'summarizing',
      'summarized',
      'failed'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'segment_upload_status') then
    create type public.segment_upload_status as enum (
      'pending',
      'ticket_issued',
      'uploading',
      'uploaded',
      'failed'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'pipeline_stage') then
    create type public.pipeline_stage as enum (
      'ticket_issue',
      'watch_upload',
      'metadata_upsert',
      'finalize',
      'transcribe',
      'summarize',
      'ask',
      'notes',
      'cleanup',
      'ingest_events'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'limit_mode') then
    create type public.limit_mode as enum ('monitor', 'enforce');
  end if;
end
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_profiles (user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email))
  on conflict (user_id) do nothing;

  insert into public.user_usage_quotas (id, user_id, daily_audio_seconds_limit, is_enabled)
  values (gen_random_uuid(), new.id, 3600, true)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  timezone text,
  locale text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  platform public.platform_type not null,
  app_version text,
  os_version text,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, device_id)
);

create table if not exists public.user_consent_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  consent_type text not null,
  consent_version text not null,
  accepted boolean not null,
  occurred_at timestamptz not null,
  request_id uuid,
  properties jsonb not null default '{}'::jsonb
);

create table if not exists public.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  action_key text not null,
  idempotency_key text not null,
  request_hash text,
  first_response jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, action_key, idempotency_key)
);

create table if not exists public.watch_upload_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  segment_index int not null check (segment_index >= 0),
  storage_path text not null,
  signed_upload_url text not null,
  expires_at timestamptz not null,
  issued_to_device_id text not null,
  consumed_at timestamptz,
  request_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_sessions (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_device_id text,
  language text not null default 'en' check (language = 'en'),
  started_at timestamptz not null,
  ended_at timestamptz,
  status public.session_status not null default 'sync_pending',
  total_duration_ms int,
  segment_count int not null default 0,
  latest_error_code text,
  latest_error_message text,
  request_id uuid,
  correlation_id uuid default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_segments (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  segment_index int not null check (segment_index >= 0),
  storage_path text not null,
  upload_status public.segment_upload_status not null default 'pending',
  uploaded_from text not null default 'watch' check (uploaded_from in ('watch', 'phone_fallback')),
  duration_ms int,
  bytes bigint,
  content_sha256 text,
  started_at timestamptz,
  ended_at timestamptz,
  request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, segment_index)
);

create table if not exists public.session_sync_attempts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempt_no int not null,
  stage text not null,
  status text not null check (status in ('started', 'succeeded', 'failed')),
  error_code text,
  error_message text,
  duration_ms int,
  request_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.session_stage_transitions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  from_status public.session_status,
  to_status public.session_status not null,
  reason text,
  request_id uuid,
  correlation_id uuid,
  actor_platform public.platform_type,
  occurred_at timestamptz not null default now()
);

create table if not exists public.conversation_failures (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  stage public.pipeline_stage not null,
  error_code text not null,
  error_message text,
  is_retryable boolean not null default true,
  retry_after_seconds int,
  request_id uuid,
  correlation_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.prompt_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  version int not null,
  kind text not null check (kind in ('summary', 'qa')),
  template_text text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (name, version)
);

create table if not exists public.conversation_transcripts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null unique references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  transcript_text text not null,
  segments_json jsonb not null default '[]'::jsonb,
  language text not null default 'en' check (language = 'en'),
  model text,
  audio_seconds numeric(10, 2),
  tokens_in int,
  request_id uuid,
  correlation_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_summaries (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  summary_prompt_name text not null,
  summary_prompt_version int not null,
  summary_text text not null,
  model text,
  tokens_in int,
  tokens_out int,
  request_id uuid,
  correlation_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, summary_prompt_name, summary_prompt_version)
);

create table if not exists public.conversation_notes (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  note_text text not null,
  version int not null default 1,
  request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, user_id)
);

create table if not exists public.conversation_questions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  question text not null,
  answer text,
  status text not null default 'pending' check (status in ('pending', 'answered', 'failed')),
  model text,
  tokens_in int,
  tokens_out int,
  latency_ms int,
  error_code text,
  request_id uuid,
  correlation_id uuid,
  created_at timestamptz not null default now(),
  answered_at timestamptz
);

create table if not exists public.ai_model_calls (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  session_id uuid references public.conversation_sessions(id) on delete cascade,
  question_id uuid references public.conversation_questions(id) on delete set null,
  stage public.pipeline_stage not null,
  provider text not null default 'openai',
  model text not null,
  prompt_template_name text,
  prompt_template_version int,
  tokens_in int,
  tokens_out int,
  audio_seconds numeric(10, 2),
  latency_ms int,
  estimated_cost_usd numeric(10, 6),
  request_id uuid,
  correlation_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.user_usage_quotas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  daily_audio_seconds_limit int not null default 3600,
  is_enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (user_id)
);

create table if not exists public.user_daily_audio_usage (
  usage_date date not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  transcribed_audio_seconds int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (usage_date, user_id)
);

create table if not exists public.quota_decisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  action_key text not null,
  request_id uuid,
  allowed boolean not null,
  limit_value int not null,
  current_value int not null,
  window_start date not null,
  decided_at timestamptz not null default now()
);

create table if not exists public.api_usage_counters (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null,
  scope_id text not null,
  action_key text not null,
  window_start timestamptz not null,
  window_seconds int not null,
  request_count int not null default 0,
  updated_at timestamptz not null default now(),
  unique (scope_type, scope_id, action_key, window_start, window_seconds)
);

create table if not exists public.rate_limit_rules (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null,
  action_key text not null,
  window_seconds int not null,
  max_requests int not null,
  mode public.limit_mode not null default 'monitor',
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  unique (scope_type, action_key, window_seconds)
);

create table if not exists public.rate_limit_decisions (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null,
  scope_id text not null,
  action_key text not null,
  request_id uuid,
  allowed boolean not null,
  rule_id uuid references public.rate_limit_rules(id) on delete set null,
  mode public.limit_mode not null,
  current_count int,
  max_requests int,
  retry_after_seconds int,
  decided_at timestamptz not null default now()
);

create table if not exists public.cost_budget_rules (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null,
  scope_id text not null,
  period text not null default 'weekly',
  cap_usd numeric(10, 2) not null,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  unique (scope_type, scope_id, period)
);

create table if not exists public.cost_budget_windows (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null,
  scope_id text not null,
  window_start date not null,
  window_end date not null,
  spent_usd numeric(10, 6) not null default 0,
  updated_at timestamptz not null default now(),
  unique (scope_type, scope_id, window_start, window_end)
);

create table if not exists public.cost_budget_alerts (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.cost_budget_rules(id) on delete cascade,
  window_id uuid not null references public.cost_budget_windows(id) on delete cascade,
  threshold_percent int not null,
  triggered_at timestamptz not null default now(),
  unique (rule_id, window_id, threshold_percent)
);

create table if not exists public.app_events (
  id uuid primary key default gen_random_uuid(),
  event_id text,
  user_id uuid references auth.users(id) on delete cascade,
  device_id text not null,
  platform public.platform_type not null,
  event_name text not null,
  event_version int not null default 1,
  app_session_id uuid,
  conversation_session_id uuid references public.conversation_sessions(id) on delete set null,
  request_id uuid,
  correlation_id uuid,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  properties jsonb not null default '{}'::jsonb,
  app_version text,
  build_number text,
  os_version text
);

create unique index if not exists app_events_platform_event_id_idx
  on public.app_events (platform, event_id)
  where event_id is not null;

create table if not exists public.event_ingest_batches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  device_id text,
  request_id uuid,
  batch_size int not null,
  accepted_count int not null,
  rejected_count int not null,
  first_event_at timestamptz,
  last_event_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.function_invocations (
  id uuid primary key default gen_random_uuid(),
  function_name text not null,
  user_id uuid references auth.users(id) on delete cascade,
  request_id uuid,
  correlation_id uuid,
  status_code int,
  duration_ms int,
  result text not null check (result in ('ok', 'error')),
  error_code text,
  error_message text,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_usage_rollups (
  usage_date date not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  app_opens int not null default 0,
  recording_starts int not null default 0,
  recording_stops int not null default 0,
  sessions_finalized int not null default 0,
  transcriptions_completed int not null default 0,
  summaries_completed int not null default 0,
  questions_asked int not null default 0,
  created_at timestamptz not null default now(),
  primary key (usage_date, user_id)
);

create table if not exists public.data_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('requested', 'running', 'completed', 'failed')),
  requested_at timestamptz not null default now(),
  completed_at timestamptz,
  request_id uuid,
  error_code text,
  error_message text
);

create or replace function public.refresh_session_totals()
returns trigger
language plpgsql
as $$
declare
  target_session_id uuid;
begin
  target_session_id := coalesce(new.session_id, old.session_id);

  update public.conversation_sessions
  set
    segment_count = (
      select count(*)::int
      from public.conversation_segments
      where session_id = target_session_id
    ),
    total_duration_ms = (
      select coalesce(sum(duration_ms), 0)::int
      from public.conversation_segments
      where session_id = target_session_id
    ),
    updated_at = now()
  where id = target_session_id;

  return coalesce(new, old);
end;
$$;

create or replace function public.check_rate_limit(
  p_scope_type text,
  p_scope_id text,
  p_action_key text,
  p_request_id uuid
)
returns table (
  allowed boolean,
  retry_after_seconds int,
  mode public.limit_mode,
  current_count int,
  max_requests int,
  triggered_rule_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_rule record;
  v_counter record;
  v_allowed boolean := true;
  v_retry_after int := null;
  v_mode public.limit_mode := 'monitor';
  v_current_count int := 0;
  v_max_requests int := 0;
  v_triggered_rule_id uuid := null;
  v_window_start timestamptz;
begin
  for v_rule in
    select *
    from public.rate_limit_rules
    where scope_type = p_scope_type
      and action_key = p_action_key
      and is_enabled = true
    order by window_seconds asc
  loop
    v_window_start := to_timestamp(
      floor(extract(epoch from v_now) / v_rule.window_seconds) * v_rule.window_seconds
    );

    insert into public.api_usage_counters (
      scope_type,
      scope_id,
      action_key,
      window_start,
      window_seconds,
      request_count,
      updated_at
    )
    values (
      p_scope_type,
      p_scope_id,
      p_action_key,
      v_window_start,
      v_rule.window_seconds,
      1,
      v_now
    )
    on conflict (scope_type, scope_id, action_key, window_start, window_seconds)
    do update
      set
        request_count = public.api_usage_counters.request_count + 1,
        updated_at = excluded.updated_at
    returning * into v_counter;

    if v_counter.request_count > v_rule.max_requests then
      v_allowed := false;
      v_retry_after := greatest(
        1,
        v_rule.window_seconds - extract(epoch from (v_now - v_window_start))::int
      );
      v_mode := v_rule.mode;
      v_current_count := v_counter.request_count;
      v_max_requests := v_rule.max_requests;
      v_triggered_rule_id := v_rule.id;
    end if;

    insert into public.rate_limit_decisions (
      scope_type,
      scope_id,
      action_key,
      request_id,
      allowed,
      rule_id,
      mode,
      current_count,
      max_requests,
      retry_after_seconds
    )
    values (
      p_scope_type,
      p_scope_id,
      p_action_key,
      p_request_id,
      case
        when v_counter.request_count > v_rule.max_requests and v_rule.mode = 'enforce' then false
        else true
      end,
      v_rule.id,
      v_rule.mode,
      v_counter.request_count,
      v_rule.max_requests,
      case
        when v_counter.request_count > v_rule.max_requests then v_retry_after
        else null
      end
    );
  end loop;

  if v_triggered_rule_id is null then
    return query
    select true, null::int, 'monitor'::public.limit_mode, 0, 0, null::uuid;
  elsif v_mode = 'monitor' then
    return query
    select true, v_retry_after, v_mode, v_current_count, v_max_requests, v_triggered_rule_id;
  else
    return query
    select false, v_retry_after, v_mode, v_current_count, v_max_requests, v_triggered_rule_id;
  end if;
end;
$$;

create or replace view public.session_feed_view
with (security_invoker = true)
as
select
  s.id as session_id,
  s.user_id,
  s.started_at,
  s.ended_at,
  s.status,
  s.segment_count,
  s.total_duration_ms,
  n.note_text as user_notes,
  left(ds.summary_text, 220) as latest_summary_excerpt,
  (
    select count(*)::int
    from public.conversation_questions q
    where q.session_id = s.id
  ) as question_count,
  s.latest_error_code,
  s.updated_at
from public.conversation_sessions s
left join public.conversation_notes n
  on n.session_id = s.id
 and n.user_id = s.user_id
left join lateral (
  select summary_text
  from public.conversation_summaries cs
  where cs.session_id = s.id
    and cs.summary_prompt_name = 'say_prompt_default'
  order by cs.summary_prompt_version desc, cs.created_at desc
  limit 1
) ds on true;

create or replace view public.question_history_view
with (security_invoker = true)
as
select
  q.id as question_id,
  q.session_id,
  q.user_id,
  q.question,
  q.answer,
  q.status,
  q.model,
  q.tokens_in,
  q.tokens_out,
  q.latency_ms,
  q.error_code,
  q.request_id,
  q.correlation_id,
  q.created_at,
  q.answered_at
from public.conversation_questions q;

create or replace view public.session_detail_view
with (security_invoker = true)
as
select
  s.id as session_id,
  s.user_id,
  s.started_at,
  s.ended_at,
  s.status,
  s.segment_count,
  s.total_duration_ms,
  s.latest_error_code,
  s.latest_error_message,
  t.transcript_text,
  t.language as transcript_language,
  t.model as transcript_model,
  n.note_text as user_notes,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'summary_id', cs.id,
          'prompt_name', cs.summary_prompt_name,
          'prompt_version', cs.summary_prompt_version,
          'summary_text', cs.summary_text,
          'model', cs.model,
          'created_at', cs.created_at
        )
        order by cs.created_at asc
      )
      from public.conversation_summaries cs
      where cs.session_id = s.id
    ),
    '[]'::jsonb
  ) as summaries,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'question_id', q.id,
          'question', q.question,
          'answer', q.answer,
          'status', q.status,
          'model', q.model,
          'created_at', q.created_at,
          'answered_at', q.answered_at
        )
        order by q.created_at asc
      )
      from public.conversation_questions q
      where q.session_id = s.id
    ),
    '[]'::jsonb
  ) as questions
from public.conversation_sessions s
left join public.conversation_transcripts t on t.session_id = s.id
left join public.conversation_notes n
  on n.session_id = s.id
 and n.user_id = s.user_id;

create index if not exists conversation_sessions_user_started_idx
  on public.conversation_sessions (user_id, started_at desc);
create index if not exists conversation_sessions_status_idx
  on public.conversation_sessions (status, updated_at desc);
create index if not exists conversation_segments_session_segment_idx
  on public.conversation_segments (session_id, segment_index);
create index if not exists conversation_segments_status_idx
  on public.conversation_segments (upload_status, updated_at desc);
create index if not exists conversation_failures_session_created_idx
  on public.conversation_failures (session_id, created_at desc);
create index if not exists conversation_summaries_session_prompt_idx
  on public.conversation_summaries (session_id, summary_prompt_name, summary_prompt_version desc);
create index if not exists conversation_questions_session_created_idx
  on public.conversation_questions (session_id, created_at desc);
create index if not exists app_events_conversation_occurred_idx
  on public.app_events (conversation_session_id, occurred_at desc);
create index if not exists function_invocations_function_created_idx
  on public.function_invocations (function_name, created_at desc);
create index if not exists ai_model_calls_stage_created_idx
  on public.ai_model_calls (stage, created_at desc);

drop trigger if exists trg_user_profiles_updated_at on public.user_profiles;
create trigger trg_user_profiles_updated_at
before update on public.user_profiles
for each row execute function public.set_updated_at();

drop trigger if exists trg_user_devices_updated_at on public.user_devices;
create trigger trg_user_devices_updated_at
before update on public.user_devices
for each row execute function public.set_updated_at();

drop trigger if exists trg_sessions_updated_at on public.conversation_sessions;
create trigger trg_sessions_updated_at
before update on public.conversation_sessions
for each row execute function public.set_updated_at();

drop trigger if exists trg_segments_updated_at on public.conversation_segments;
create trigger trg_segments_updated_at
before update on public.conversation_segments
for each row execute function public.set_updated_at();

drop trigger if exists trg_segments_refresh_totals on public.conversation_segments;
create trigger trg_segments_refresh_totals
after insert or update or delete on public.conversation_segments
for each row execute function public.refresh_session_totals();

drop trigger if exists trg_transcripts_updated_at on public.conversation_transcripts;
create trigger trg_transcripts_updated_at
before update on public.conversation_transcripts
for each row execute function public.set_updated_at();

drop trigger if exists trg_summaries_updated_at on public.conversation_summaries;
create trigger trg_summaries_updated_at
before update on public.conversation_summaries
for each row execute function public.set_updated_at();

drop trigger if exists trg_notes_updated_at on public.conversation_notes;
create trigger trg_notes_updated_at
before update on public.conversation_notes
for each row execute function public.set_updated_at();

drop trigger if exists trg_auth_new_user on auth.users;
create trigger trg_auth_new_user
after insert on auth.users
for each row execute function public.handle_new_user();

alter table public.user_profiles enable row level security;
alter table public.user_devices enable row level security;
alter table public.user_consent_events enable row level security;
alter table public.conversation_sessions enable row level security;
alter table public.conversation_segments enable row level security;
alter table public.conversation_transcripts enable row level security;
alter table public.conversation_summaries enable row level security;
alter table public.conversation_notes enable row level security;
alter table public.conversation_questions enable row level security;
alter table public.conversation_failures enable row level security;
alter table public.session_sync_attempts enable row level security;
alter table public.session_stage_transitions enable row level security;
alter table public.daily_usage_rollups enable row level security;

drop policy if exists "user_profiles_select" on public.user_profiles;
create policy "user_profiles_select" on public.user_profiles for select using (auth.uid() = user_id);
drop policy if exists "user_profiles_insert" on public.user_profiles;
create policy "user_profiles_insert" on public.user_profiles for insert with check (auth.uid() = user_id);
drop policy if exists "user_profiles_update" on public.user_profiles;
create policy "user_profiles_update" on public.user_profiles for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "user_profiles_delete" on public.user_profiles;
create policy "user_profiles_delete" on public.user_profiles for delete using (auth.uid() = user_id);

drop policy if exists "user_devices_select" on public.user_devices;
create policy "user_devices_select" on public.user_devices for select using (auth.uid() = user_id);
drop policy if exists "user_devices_insert" on public.user_devices;
create policy "user_devices_insert" on public.user_devices for insert with check (auth.uid() = user_id);
drop policy if exists "user_devices_update" on public.user_devices;
create policy "user_devices_update" on public.user_devices for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "user_devices_delete" on public.user_devices;
create policy "user_devices_delete" on public.user_devices for delete using (auth.uid() = user_id);

drop policy if exists "user_consent_events_select" on public.user_consent_events;
create policy "user_consent_events_select" on public.user_consent_events for select using (auth.uid() = user_id);
drop policy if exists "user_consent_events_insert" on public.user_consent_events;
create policy "user_consent_events_insert" on public.user_consent_events for insert with check (auth.uid() = user_id);
drop policy if exists "user_consent_events_update" on public.user_consent_events;
create policy "user_consent_events_update" on public.user_consent_events for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "user_consent_events_delete" on public.user_consent_events;
create policy "user_consent_events_delete" on public.user_consent_events for delete using (auth.uid() = user_id);

drop policy if exists "conversation_sessions_select" on public.conversation_sessions;
create policy "conversation_sessions_select" on public.conversation_sessions for select using (auth.uid() = user_id);
drop policy if exists "conversation_sessions_insert" on public.conversation_sessions;
create policy "conversation_sessions_insert" on public.conversation_sessions for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_sessions_update" on public.conversation_sessions;
create policy "conversation_sessions_update" on public.conversation_sessions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_sessions_delete" on public.conversation_sessions;
create policy "conversation_sessions_delete" on public.conversation_sessions for delete using (auth.uid() = user_id);

drop policy if exists "conversation_segments_select" on public.conversation_segments;
create policy "conversation_segments_select" on public.conversation_segments for select using (auth.uid() = user_id);
drop policy if exists "conversation_segments_insert" on public.conversation_segments;
create policy "conversation_segments_insert" on public.conversation_segments for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_segments_update" on public.conversation_segments;
create policy "conversation_segments_update" on public.conversation_segments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_segments_delete" on public.conversation_segments;
create policy "conversation_segments_delete" on public.conversation_segments for delete using (auth.uid() = user_id);

drop policy if exists "conversation_transcripts_select" on public.conversation_transcripts;
create policy "conversation_transcripts_select" on public.conversation_transcripts for select using (auth.uid() = user_id);
drop policy if exists "conversation_transcripts_insert" on public.conversation_transcripts;
create policy "conversation_transcripts_insert" on public.conversation_transcripts for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_transcripts_update" on public.conversation_transcripts;
create policy "conversation_transcripts_update" on public.conversation_transcripts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_transcripts_delete" on public.conversation_transcripts;
create policy "conversation_transcripts_delete" on public.conversation_transcripts for delete using (auth.uid() = user_id);

drop policy if exists "conversation_summaries_select" on public.conversation_summaries;
create policy "conversation_summaries_select" on public.conversation_summaries for select using (auth.uid() = user_id);
drop policy if exists "conversation_summaries_insert" on public.conversation_summaries;
create policy "conversation_summaries_insert" on public.conversation_summaries for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_summaries_update" on public.conversation_summaries;
create policy "conversation_summaries_update" on public.conversation_summaries for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_summaries_delete" on public.conversation_summaries;
create policy "conversation_summaries_delete" on public.conversation_summaries for delete using (auth.uid() = user_id);

drop policy if exists "conversation_notes_select" on public.conversation_notes;
create policy "conversation_notes_select" on public.conversation_notes for select using (auth.uid() = user_id);
drop policy if exists "conversation_notes_insert" on public.conversation_notes;
create policy "conversation_notes_insert" on public.conversation_notes for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_notes_update" on public.conversation_notes;
create policy "conversation_notes_update" on public.conversation_notes for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_notes_delete" on public.conversation_notes;
create policy "conversation_notes_delete" on public.conversation_notes for delete using (auth.uid() = user_id);

drop policy if exists "conversation_questions_select" on public.conversation_questions;
create policy "conversation_questions_select" on public.conversation_questions for select using (auth.uid() = user_id);
drop policy if exists "conversation_questions_insert" on public.conversation_questions;
create policy "conversation_questions_insert" on public.conversation_questions for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_questions_update" on public.conversation_questions;
create policy "conversation_questions_update" on public.conversation_questions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_questions_delete" on public.conversation_questions;
create policy "conversation_questions_delete" on public.conversation_questions for delete using (auth.uid() = user_id);

drop policy if exists "conversation_failures_select" on public.conversation_failures;
create policy "conversation_failures_select" on public.conversation_failures for select using (auth.uid() = user_id);
drop policy if exists "conversation_failures_insert" on public.conversation_failures;
create policy "conversation_failures_insert" on public.conversation_failures for insert with check (auth.uid() = user_id);
drop policy if exists "conversation_failures_update" on public.conversation_failures;
create policy "conversation_failures_update" on public.conversation_failures for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "conversation_failures_delete" on public.conversation_failures;
create policy "conversation_failures_delete" on public.conversation_failures for delete using (auth.uid() = user_id);

drop policy if exists "session_sync_attempts_select" on public.session_sync_attempts;
create policy "session_sync_attempts_select" on public.session_sync_attempts for select using (auth.uid() = user_id);
drop policy if exists "session_sync_attempts_insert" on public.session_sync_attempts;
create policy "session_sync_attempts_insert" on public.session_sync_attempts for insert with check (auth.uid() = user_id);
drop policy if exists "session_sync_attempts_update" on public.session_sync_attempts;
create policy "session_sync_attempts_update" on public.session_sync_attempts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "session_sync_attempts_delete" on public.session_sync_attempts;
create policy "session_sync_attempts_delete" on public.session_sync_attempts for delete using (auth.uid() = user_id);

drop policy if exists "session_stage_transitions_select" on public.session_stage_transitions;
create policy "session_stage_transitions_select" on public.session_stage_transitions for select using (auth.uid() = user_id);
drop policy if exists "session_stage_transitions_insert" on public.session_stage_transitions;
create policy "session_stage_transitions_insert" on public.session_stage_transitions for insert with check (auth.uid() = user_id);
drop policy if exists "session_stage_transitions_update" on public.session_stage_transitions;
create policy "session_stage_transitions_update" on public.session_stage_transitions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "session_stage_transitions_delete" on public.session_stage_transitions;
create policy "session_stage_transitions_delete" on public.session_stage_transitions for delete using (auth.uid() = user_id);

drop policy if exists "daily_usage_rollups_select" on public.daily_usage_rollups;
create policy "daily_usage_rollups_select" on public.daily_usage_rollups for select using (auth.uid() = user_id);
drop policy if exists "daily_usage_rollups_insert" on public.daily_usage_rollups;
create policy "daily_usage_rollups_insert" on public.daily_usage_rollups for insert with check (auth.uid() = user_id);
drop policy if exists "daily_usage_rollups_update" on public.daily_usage_rollups;
create policy "daily_usage_rollups_update" on public.daily_usage_rollups for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "daily_usage_rollups_delete" on public.daily_usage_rollups;
create policy "daily_usage_rollups_delete" on public.daily_usage_rollups for delete using (auth.uid() = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'conversation-audio',
  'conversation-audio',
  false,
  26214400,
  array['audio/m4a', 'audio/mp4', 'audio/aac']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter publication supabase_realtime add table public.conversation_sessions;
alter publication supabase_realtime add table public.conversation_transcripts;
alter publication supabase_realtime add table public.conversation_summaries;
alter publication supabase_realtime add table public.conversation_questions;
alter publication supabase_realtime add table public.conversation_notes;
alter publication supabase_realtime add table public.conversation_failures;
