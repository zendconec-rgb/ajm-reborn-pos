-- AJM Reborn POS — Phase 1 additive multi-device foundation
-- Target: existing Supabase project. Run only after reviewing/backing up production.
-- SAFE SCOPE:
--   * Does NOT alter or delete public.ajm_pos_database or its payload.
--   * Adds device registry + append-only sync inbox for idempotent offline operations.
--   * Does NOT yet change the existing AJM HTML or replace ajm_pos_save.
--   * Does NOT claim Admin/Kasir authorization is complete; role mapping must be
--     connected to the application's real user model in a later migration.
--
-- Prerequisites: Supabase Auth (auth.uid()) and pgcrypto/gen_random_uuid().
-- Apply as one script in Supabase SQL Editor.

begin;

create table if not exists public.ajm_devices (
  device_key text primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  device_name text not null,
  app_version text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint ajm_devices_device_key_nonempty check (length(trim(device_key)) between 8 and 128),
  constraint ajm_devices_device_name_nonempty check (length(trim(device_name)) between 1 and 120)
);

create index if not exists ajm_devices_user_active_idx
  on public.ajm_devices(user_id, is_active);

create table if not exists public.ajm_sync_operations (
  operation_id uuid primary key,
  device_key text not null references public.ajm_devices(device_key) on update cascade on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  operation_type text not null,
  payload jsonb not null,
  client_created_at timestamptz,
  received_at timestamptz not null default now(),
  processing_status text not null default 'pending',
  processing_error text,
  constraint ajm_sync_operations_type_nonempty check (length(trim(operation_type)) between 1 and 80),
  constraint ajm_sync_operations_payload_object check (jsonb_typeof(payload) = 'object'),
  constraint ajm_sync_operations_status_check check (processing_status in ('pending','processed','conflict','rejected'))
);

create index if not exists ajm_sync_operations_user_received_idx
  on public.ajm_sync_operations(user_id, received_at desc);

create index if not exists ajm_sync_operations_device_received_idx
  on public.ajm_sync_operations(device_key, received_at desc);

alter table public.ajm_devices enable row level security;
alter table public.ajm_sync_operations enable row level security;

-- Remove/recreate only this migration's own policies, making reruns predictable.
drop policy if exists "AJM users read own devices" on public.ajm_devices;
create policy "AJM users read own devices"
  on public.ajm_devices for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "AJM users register own devices" on public.ajm_devices;
create policy "AJM users register own devices"
  on public.ajm_devices for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "AJM users update own devices" on public.ajm_devices;
create policy "AJM users update own devices"
  on public.ajm_devices for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "AJM users read own sync operations" on public.ajm_sync_operations;
create policy "AJM users read own sync operations"
  on public.ajm_sync_operations for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "AJM users submit own device operations" on public.ajm_sync_operations;
create policy "AJM users submit own device operations"
  on public.ajm_sync_operations for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.ajm_devices d
      where d.device_key = ajm_sync_operations.device_key
        and d.user_id = (select auth.uid())
        and d.is_active = true
    )
  );

-- Register or refresh a device for the currently authenticated user.
-- Device key is generated and retained by the client; never use a service-role key.
create or replace function public.ajm_register_device(
  p_device_key text,
  p_device_name text,
  p_app_version text default null
)
returns table(device_key text, user_id uuid, is_active boolean, last_seen_at timestamptz)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
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

  insert into public.ajm_devices as d
    (device_key, user_id, device_name, app_version, is_active, last_seen_at)
  values
    (p_device_key, v_user_id, trim(p_device_name), p_app_version, true, now())
  on conflict (device_key) do update
    set device_name = excluded.device_name,
        app_version = excluded.app_version,
        is_active = true,
        last_seen_at = now()
    where d.user_id = v_user_id;

  if not found then
    raise exception 'AJM_DEVICE_OWNED_BY_ANOTHER_USER' using errcode = '42501';
  end if;

  return query
    select d.device_key, d.user_id, d.is_active, d.last_seen_at
    from public.ajm_devices d
    where d.device_key = p_device_key
      and d.user_id = v_user_id;
end;
$$;

-- Append-only, idempotent operation submission.
-- Replaying the same operation_id returns the existing row and never duplicates it.
create or replace function public.ajm_submit_sync_operation(
  p_operation_id uuid,
  p_device_key text,
  p_operation_type text,
  p_payload jsonb,
  p_client_created_at timestamptz default null
)
returns table(operation_id uuid, received_at timestamptz, processing_status text, inserted boolean)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_inserted boolean := false;
begin
  if v_user_id is null then
    raise exception 'AJM_AUTH_REQUIRED' using errcode = '28000';
  end if;
  if p_operation_id is null then
    raise exception 'AJM_OPERATION_ID_REQUIRED' using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'AJM_PAYLOAD_MUST_BE_OBJECT' using errcode = '22023';
  end if;

  insert into public.ajm_sync_operations
    (operation_id, device_key, user_id, operation_type, payload, client_created_at)
  select
    p_operation_id, d.device_key, v_user_id, trim(p_operation_type), p_payload, p_client_created_at
  from public.ajm_devices d
  where d.device_key = p_device_key
    and d.user_id = v_user_id
    and d.is_active = true
    and p_operation_type is not null
    and length(trim(p_operation_type)) between 1 and 80
  on conflict (operation_id) do nothing;

  v_inserted := found;

  return query
    select o.operation_id, o.received_at, o.processing_status, v_inserted
    from public.ajm_sync_operations o
    where o.operation_id = p_operation_id
      and o.user_id = v_user_id;
end;
$$;

revoke all on function public.ajm_register_device(text, text, text) from public;
grant execute on function public.ajm_register_device(text, text, text) to authenticated;

revoke all on function public.ajm_submit_sync_operation(uuid, text, text, jsonb, timestamptz) from public;
grant execute on function public.ajm_submit_sync_operation(uuid, text, text, jsonb, timestamptz) to authenticated;

grant select, insert, update on public.ajm_devices to authenticated;
grant select, insert on public.ajm_sync_operations to authenticated;

-- Enable Realtime for the new tables without changing existing publication members.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'ajm_devices'
  ) then
    alter publication supabase_realtime add table public.ajm_devices;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'ajm_sync_operations'
  ) then
    alter publication supabase_realtime add table public.ajm_sync_operations;
  end if;
end;
$$;

commit;

-- POST-MIGRATION VERIFICATION (run separately after successful commit):
-- select tablename, rowsecurity from pg_tables
-- where schemaname='public' and tablename in ('ajm_pos_database','ajm_devices','ajm_sync_operations')
-- order by tablename;
--
-- select pubname, schemaname, tablename from pg_publication_tables
-- where pubname='supabase_realtime' and schemaname='public'
-- order by tablename;
--
-- IMPORTANT NEXT PHASE:
-- This is a durable device registry + idempotent offline-operation inbox only.
-- Do not enable app writes to this inbox until the client IndexedDB queue and
-- server-side transaction/stock processor are implemented and tested.
-- Admin/Kasir role enforcement, transaction normalization, stock locking,
-- conflict resolution, and legacy snapshot migration are deliberately deferred.
