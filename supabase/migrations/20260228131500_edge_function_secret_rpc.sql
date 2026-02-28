create or replace function public.get_edge_secret(p_name text)
returns text
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  secret_value text;
begin
  if p_name not in ('internal_job_secret', 'openai_api_key') then
    raise exception 'Secret % is not available to edge functions', p_name;
  end if;

  select decrypted_secret
  into secret_value
  from vault.decrypted_secrets
  where name = p_name;

  return secret_value;
end;
$$;

create or replace function public.is_valid_internal_job_secret(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  expected_secret text;
begin
  select decrypted_secret
  into expected_secret
  from vault.decrypted_secrets
  where name = 'internal_job_secret';

  if expected_secret is null then
    raise exception 'Vault secret internal_job_secret is not configured';
  end if;

  return p_secret is not null and p_secret = expected_secret;
end;
$$;

revoke all on function public.get_edge_secret(text) from public, anon, authenticated;
grant execute on function public.get_edge_secret(text) to service_role;

revoke all on function public.is_valid_internal_job_secret(text) from public, anon, authenticated;
grant execute on function public.is_valid_internal_job_secret(text) to service_role;
