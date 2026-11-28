-- AJM Reborn POS — Phase 4 link local AJM login identity to Supabase Auth
-- This is a bridge, not a replacement for Supabase Auth.
-- Each operator must use their own Supabase Auth account; do not share one cloud
-- Admin account across local cashier logins.
-- Apply only after phases 1-3 and after the Admin role has been bootstrapped.

begin;

create table if not exists public.ajm_local_identity_links (
  local_user_id text primary key,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  local_username text not null,
  local_role text not null check (local_role in ('Admin','Kasir')),
  linked_at timestamptz not null default now(),
  last_verified_at timestamptz not null default now()
);

alter table public.ajm_local_identity_links enable row level security;

drop policy if exists "AJM users read own local identity link" on public.ajm_local_identity_links;
create policy "AJM users read own local identity link"
  on public.ajm_local_identity_links for select to authenticated
  using (auth_user_id = (select auth.uid()));

grant select on public.ajm_local_identity_links to authenticated;

create or replace function public.ajm_link_local_identity(
  p_local_user_id text,
  p_local_username text,
  p_local_role text
)
returns table(local_user_id text, auth_user_id uuid, local_role text, linked_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_auth_user uuid := auth.uid();
  v_server_role text;
  v_existing_auth uuid;
begin
  if v_auth_user is null then
    raise exception 'AJM_AUTH_REQUIRED' using errcode = '28000';
  end if;

  if coalesce(length(trim(p_local_user_id)),0) not between 1 and 160
     or coalesce(length(trim(p_local_username)),0) not between 1 and 80
     or p_local_role not in ('Admin','Kasir') then
    raise exception 'AJM_INVALID_LOCAL_IDENTITY' using errcode = '22023';
  end if;

  select r.app_role into v_server_role
  from public.ajm_user_roles r
  where r.user_id = v_auth_user and r.is_active = true;

  if v_server_role is null then
    raise exception 'AJM_SERVER_ROLE_NOT_CONFIGURED' using errcode = '42501';
  end if;

  if v_server_role <> p_local_role then
    raise exception 'AJM_LOCAL_SERVER_ROLE_MISMATCH' using errcode = '42501';
  end if;

  select l.auth_user_id into v_existing_auth
  from public.ajm_local_identity_links l
  where l.local_user_id = p_local_user_id;

  if v_existing_auth is not null and v_existing_auth <> v_auth_user then
    raise exception 'AJM_LOCAL_IDENTITY_ALREADY_LINKED' using errcode = '23505';
  end if;

  insert into public.ajm_local_identity_links as l
    (local_user_id, auth_user_id, local_username, local_role, linked_at, last_verified_at)
  values
    (p_local_user_id, v_auth_user, trim(p_local_username), p_local_role, now(), now())
  on conflict (local_user_id) do update
    set local_username = excluded.local_username,
        local_role = excluded.local_role,
        last_verified_at = now()
    where l.auth_user_id = v_auth_user;

  if not found then
    raise exception 'AJM_LOCAL_IDENTITY_ALREADY_LINKED' using errcode = '23505';
  end if;

  return query
    select l.local_user_id, l.auth_user_id, l.local_role, l.linked_at
    from public.ajm_local_identity_links l
    where l.local_user_id = p_local_user_id
      and l.auth_user_id = v_auth_user;
end;
$function$;

revoke all on function public.ajm_link_local_identity(text,text,text) from public;
grant execute on function public.ajm_link_local_identity(text,text,text) to authenticated;

commit;

-- Admin must create a Supabase Auth user for each operator and assign matching
-- Admin/Kasir roles using ajm_admin_set_user_role before the operator links.
-- The local login alone never grants server permissions.
