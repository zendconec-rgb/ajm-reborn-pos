-- AJM Reborn POS — Phase 6: harden device revocation
-- Fixes two paths that could otherwise reactivate an Admin-revoked device:
--   1) authenticated users previously had direct UPDATE permission on ajm_devices;
--   2) ajm_register_device previously set is_active=true on an existing key.
-- Existing device records and operation history are preserved.

begin;

-- Remove direct client-side device mutation. Device metadata is refreshed only
-- through the controlled RPC; activation/deactivation remains Admin-only.
drop policy if exists "AJM users update own devices" on public.ajm_devices;
revoke update on table public.ajm_devices from authenticated;

create or replace function public.ajm_register_device(
  p_device_key text,
  p_device_name text,
  p_app_version text default null
)
returns table(device_key text, user_id uuid, is_active boolean, last_seen_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_existing_user uuid;
  v_existing_active boolean;
begin
  if v_user_id is null then
    raise exception 'AJM_AUTH_REQUIRED' using errcode = '28000';
  end if;

  if p_device_key is null or length(trim(p_device_key)) < 8 or length(trim(p_device_key)) > 128 then
    raise exception 'AJM_INVALID_DEVICE_KEY' using errcode = '22023';
  end if;

  if p_device_name is null or length(trim(p_device_name)) < 1 or length(trim(p_device_name)) > 120 then
    raise exception 'AJM_INVALID_DEVICE_NAME' using errcode = '22023';
  end if;

  select d.user_id, d.is_active
    into v_existing_user, v_existing_active
  from public.ajm_devices d
  where d.device_key = p_device_key
  for update;

  if found then
    if v_existing_user <> v_user_id then
      raise exception 'AJM_DEVICE_OWNED_BY_ANOTHER_USER' using errcode = '42501';
    end if;

    if v_existing_active is not true then
      raise exception 'AJM_DEVICE_REVOKED_BY_ADMIN' using errcode = '42501';
    end if;

    update public.ajm_devices d
    set device_name = trim(p_device_name),
        app_version = p_app_version,
        last_seen_at = now()
    where d.device_key = p_device_key
      and d.user_id = v_user_id
      and d.is_active = true;
  else
    insert into public.ajm_devices
      (device_key, user_id, device_name, app_version, is_active, last_seen_at)
    values
      (p_device_key, v_user_id, trim(p_device_name), p_app_version, true, now());
  end if;

  return query
    select d.device_key, d.user_id, d.is_active, d.last_seen_at
    from public.ajm_devices d
    where d.device_key = p_device_key
      and d.user_id = v_user_id;
end;
$function$;

revoke all on function public.ajm_register_device(text, text, text) from public;
grant execute on function public.ajm_register_device(text, text, text) to authenticated;

commit;

-- READ-ONLY VERIFICATION (run after applying this migration):
-- 1) Authenticated users must not have direct UPDATE table privilege.
-- select has_table_privilege('authenticated','public.ajm_devices','UPDATE') as can_direct_update_devices;
-- Expected: false
--
-- 2) No ordinary-user UPDATE policy should remain.
-- select policyname, cmd from pg_policies
-- where schemaname='public' and tablename='ajm_devices' and cmd='UPDATE';
-- Expected: zero rows
--
-- 3) Controlled registration RPC must be SECURITY DEFINER.
-- select p.proname, p.prosecdef
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname='ajm_register_device';
-- Expected prosecdef=true
--
-- 4) Test with a revoked device key while authenticated as its owner:
-- select * from public.ajm_register_device('REVOKED_DEVICE_KEY','Test','test');
-- Expected: AJM_DEVICE_REVOKED_BY_ADMIN
