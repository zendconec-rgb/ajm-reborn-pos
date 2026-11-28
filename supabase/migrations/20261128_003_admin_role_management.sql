-- AJM Reborn POS — Phase 3 Admin role and device administration
-- Additive security layer. Apply only after Phase 1 + Phase 2 migrations.
-- Bootstrap the first Admin via SQL Editor as project owner (see bottom).
-- Thereafter only an active Admin can assign Admin/Kasir roles or revoke devices.

begin;

-- Admin can view all role mappings; users can still view their own role.
drop policy if exists "AJM admins read all roles" on public.ajm_user_roles;
create policy "AJM admins read all roles"
  on public.ajm_user_roles for select to authenticated
  using (
    exists (
      select 1 from public.ajm_user_roles me
      where me.user_id = (select auth.uid())
        and me.app_role = 'Admin'
        and me.is_active = true
    )
  );

-- Admin can view all posted sales; cashiers retain own-sale visibility.
drop policy if exists "AJM admins read all sales ledger" on public.ajm_sales_ledger;
create policy "AJM admins read all sales ledger"
  on public.ajm_sales_ledger for select to authenticated
  using (
    exists (
      select 1 from public.ajm_user_roles me
      where me.user_id = (select auth.uid())
        and me.app_role = 'Admin'
        and me.is_active = true
    )
  );

create or replace function public.ajm_admin_set_user_role(
  p_target_user_id uuid,
  p_app_role text,
  p_is_active boolean default true
)
returns table(user_id uuid, app_role text, is_active boolean)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_actor_role text;
begin
  if v_actor is null then
    raise exception 'AJM_AUTH_REQUIRED' using errcode = '28000';
  end if;

  select r.app_role into v_actor_role
  from public.ajm_user_roles r
  where r.user_id = v_actor and r.is_active = true;

  if v_actor_role is distinct from 'Admin' then
    raise exception 'AJM_ADMIN_REQUIRED' using errcode = '42501';
  end if;

  if p_target_user_id is null or p_app_role not in ('Admin', 'Kasir') then
    raise exception 'AJM_INVALID_ROLE_ASSIGNMENT' using errcode = '22023';
  end if;

  -- Prevent the last active Admin from accidentally disabling/demoting itself.
  if p_target_user_id = v_actor and (p_app_role <> 'Admin' or p_is_active is not true) then
    if (
      select count(*) from public.ajm_user_roles r
      where r.app_role = 'Admin' and r.is_active = true
    ) <= 1 then
      raise exception 'AJM_LAST_ADMIN_PROTECTED' using errcode = '23514';
    end if;
  end if;

  insert into public.ajm_user_roles as current_role
    (user_id, app_role, is_active, updated_at)
  values (p_target_user_id, p_app_role, coalesce(p_is_active, true), now())
  on conflict (user_id) do update
    set app_role = excluded.app_role,
        is_active = excluded.is_active,
        updated_at = now();

  return query
    select r.user_id, r.app_role, r.is_active
    from public.ajm_user_roles r
    where r.user_id = p_target_user_id;
end;
$function$;

create or replace function public.ajm_admin_set_device_active(
  p_device_key text,
  p_is_active boolean
)
returns table(device_key text, user_id uuid, is_active boolean)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'AJM_AUTH_REQUIRED' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.ajm_user_roles r
    where r.user_id = v_actor and r.app_role = 'Admin' and r.is_active = true
  ) then
    raise exception 'AJM_ADMIN_REQUIRED' using errcode = '42501';
  end if;

  update public.ajm_devices d
  set is_active = coalesce(p_is_active, false),
      last_seen_at = now()
  where d.device_key = p_device_key
  returning d.device_key, d.user_id, d.is_active
  into device_key, user_id, is_active;

  if not found then
    raise exception 'AJM_DEVICE_NOT_FOUND' using errcode = 'P0002';
  end if;

  return next;
end;
$function$;

revoke all on function public.ajm_admin_set_user_role(uuid, text, boolean) from public;
grant execute on function public.ajm_admin_set_user_role(uuid, text, boolean) to authenticated;

revoke all on function public.ajm_admin_set_device_active(text, boolean) from public;
grant execute on function public.ajm_admin_set_device_active(text, boolean) to authenticated;

commit;

-- ONE-TIME BOOTSTRAP (run as Supabase project owner in SQL Editor):
-- Replace the UUID with the actual Auth user UUID for the trusted AJM administrator.
-- Do not use a local-only AJM username/password here.
--
-- insert into public.ajm_user_roles(user_id, app_role, is_active)
-- values ('00000000-0000-0000-0000-000000000000', 'Admin', true)
-- on conflict (user_id) do update
-- set app_role='Admin', is_active=true, updated_at=now();
--
-- After bootstrap, the Admin may call ajm_admin_set_user_role for other Auth users.
