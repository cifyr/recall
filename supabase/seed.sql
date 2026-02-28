insert into public.prompt_templates (name, version, kind, template_text, is_active)
values
  (
    'say_prompt_default',
    1,
    'summary',
    'Summarize the conversation in concise prose. Include context, key takeaways, and any unresolved questions. Use only the supplied transcript and notes context.',
    true
  ),
  (
    'say_prompt_action_items',
    1,
    'summary',
    'Extract action items from the conversation. For each item include owner if stated, the task, and any due date. If none were discussed, say that clearly. Use only the supplied transcript and notes context.',
    true
  ),
  (
    'qa_grounded_default',
    1,
    'qa',
    'Answer only from the supplied transcript, summaries, and notes. If the answer is not grounded in the context, say you do not have enough information.',
    true
  )
on conflict (name, version) do update
set
  kind = excluded.kind,
  template_text = excluded.template_text,
  is_active = excluded.is_active;

insert into public.cost_budget_rules (scope_type, scope_id, period, cap_usd, is_enabled)
values ('global', 'global', 'weekly', 50.00, true)
on conflict do nothing;

insert into public.rate_limit_rules (scope_type, action_key, window_seconds, max_requests, mode, is_enabled)
values
  ('user', 'ask_session', 600, 20, 'monitor', true),
  ('device', 'ask_session', 300, 10, 'monitor', true),
  ('ip', 'ask_session', 600, 60, 'monitor', true),
  ('user', 'create_upload_ticket', 3600, 120, 'monitor', true),
  ('user', 'finalize_session', 3600, 20, 'monitor', true),
  ('device', 'ingest_events', 300, 600, 'monitor', true)
on conflict (scope_type, action_key, window_seconds) do update
set
  max_requests = excluded.max_requests,
  mode = excluded.mode,
  is_enabled = excluded.is_enabled;
