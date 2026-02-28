create extension if not exists pg_net;

create or replace function public.invoke_internal_edge_function(
  function_name text,
  payload jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  project_url text;
  internal_secret text;
begin
  select decrypted_secret
  into project_url
  from vault.decrypted_secrets
  where name = 'project_url';

  if project_url is null then
    raise exception 'Vault secret project_url is not configured';
  end if;

  select decrypted_secret
  into internal_secret
  from vault.decrypted_secrets
  where name = 'internal_job_secret';

  if internal_secret is null then
    raise exception 'Vault secret internal_job_secret is not configured';
  end if;

  return net.http_post(
    url := project_url || '/functions/v1/' || function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-job-secret', internal_secret
    ),
    body := payload,
    timeout_milliseconds := 30000
  );
end;
$$;

select cron.schedule(
  'cleanup-audio-daily',
  '0 2 * * *',
  $$select public.invoke_internal_edge_function('cleanup-audio');$$
);

select cron.schedule(
  'evaluate-cost-budgets-hourly',
  '0 * * * *',
  $$select public.invoke_internal_edge_function('evaluate-cost-budgets');$$
);
