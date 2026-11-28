-- AJM Reborn POS: secure device registry
-- Apply this migration in Supabase SQL Editor before enabling the UI.
create table if not exists public.ajm_pos_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  device_name text not null default 'Perangkat tidak dikenal',
  platform text not null default 'unknown',
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id),
  unique (user_id, device_id)
);
create index if not exists ajm_pos_devices_user_last_seen_idx
  on public.ajm_pos_devices(user_id, last_seen_at desc);
alter table public.ajm_pos_devices enable row level security;
revoke all on public.ajm_pos_devices from anon, authenticated;
grant usage on schema public to authenticated;

create or replace function public.ajm_pos_is_device_admin()
returns boolean language sql stable security definer
set search_path = '' as $$
  select coalesce((auth.jwt()->'app_metadata'->>'role') = 'admin', false)
      or coalesce((auth.jwt()->'app_metadata'->>'is_admin') = 'true', false);
$$;

create or replace function public.ajm_pos_register_device(
  p_device_id uuid, p_device_name text, p_platform text
) returns jsonb language plpgsql security definer
set search_path = '' as $$
declare v_user uuid := auth.uid(); v_row public.ajm_pos_devices%rowtype; v_count integer; v_exists boolean := false;
begin
  if v_user is null then raise exception 'AJM_DEVICE_AUTH_REQUIRED'; end if;
  select * into v_row from public.ajm_pos_devices
    where user_id=v_user and device_id=p_device_id for update;
  v_exists := found;
  if v_exists and v_row.revoked_at is not null then
    raise exception 'AJM_DEVICE_REVOKED';
  end if;
  select count(*) into v_count from public.ajm_pos_devices
    where user_id=v_user and revoked_at is null and device_id<>p_device_id;
  if not v_exists and v_count >= 2 then
    raise exception 'AJM_DEVICE_LIMIT_REACHED';
  end if;
  insert into public.ajm_pos_devices(user_id,device_id,device_name,platform,last_seen_at)
  values(v_user,p_device_id,left(coalesce(p_device_name,'Perangkat'),120),
         left(coalesce(p_platform,'unknown'),80),now())
  on conflict(user_id,device_id) do update set
    device_name=excluded.device_name, platform=excluded.platform, last_seen_at=now()
  returning * into v_row;
  return jsonb_build_object('id',v_row.id,'device_id',v_row.device_id,
    'device_name',v_row.device_name,'platform',v_row.platform,'last_seen_at',v_row.last_seen_at);
end; $$;

create or replace function public.ajm_pos_list_devices()
returns jsonb language plpgsql stable security definer
set search_path = '' as $$
begin
  if auth.uid() is null or not public.ajm_pos_is_device_admin() then
    raise exception 'AJM_DEVICE_ADMIN_REQUIRED';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',d.id,'user_id',d.user_id,'email',u.email,'device_id',d.device_id,
    'device_name',d.device_name,'platform',d.platform,'first_seen_at',d.first_seen_at,
    'last_seen_at',d.last_seen_at,'revoked_at',d.revoked_at,
    'is_online',(d.last_seen_at > now()-interval '2 minutes')
  ) order by d.last_seen_at desc)
  from public.ajm_pos_devices d left join auth.users u on u.id=d.user_id), '[]'::jsonb);
end; $$;

create or replace function public.ajm_pos_revoke_device(p_id uuid)
returns boolean language plpgsql security definer
set search_path = '' as $$
begin
  if auth.uid() is null or not public.ajm_pos_is_device_admin() then
    raise exception 'AJM_DEVICE_ADMIN_REQUIRED';
  end if;
  update public.ajm_pos_devices set revoked_at=now(), revoked_by=auth.uid()
    where id=p_id and revoked_at is null;
  return found;
end; $$;

create or replace function public.ajm_pos_restore_device(p_id uuid)
returns boolean language plpgsql security definer
set search_path = '' as $$
begin
  if auth.uid() is null or not public.ajm_pos_is_device_admin() then
    raise exception 'AJM_DEVICE_ADMIN_REQUIRED';
  end if;
  update public.ajm_pos_devices set revoked_at=null, revoked_by=null
    where id=p_id and revoked_at is not null;
  return found;
end; $$;

revoke all on function public.ajm_pos_is_device_admin() from public, anon;
revoke all on function public.ajm_pos_register_device(uuid,text,text) from public, anon;
revoke all on function public.ajm_pos_list_devices() from public, anon;
revoke all on function public.ajm_pos_revoke_device(uuid) from public, anon;
revoke all on function public.ajm_pos_restore_device(uuid) from public, anon;
grant execute on function public.ajm_pos_register_device(uuid,text,text) to authenticated;
grant execute on function public.ajm_pos_list_devices() to authenticated;
grant execute on function public.ajm_pos_revoke_device(uuid) to authenticated;
grant execute on function public.ajm_pos_restore_device(uuid) to authenticated;
