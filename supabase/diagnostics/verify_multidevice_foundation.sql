-- AJM Reborn POS — verify Phase 1 multi-device foundation
-- Read-only. Run after the migration has been applied successfully.
-- Expected: 2 tables with RLS enabled, 2 RPC functions, and both tables in Realtime.

-- 1) Tables and RLS
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as force_rls
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('ajm_devices', 'ajm_sync_operations')
  and c.relkind = 'r'
order by c.relname;

-- 2) Policies
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('ajm_devices', 'ajm_sync_operations')
order by tablename, policyname;

-- 3) RPC signatures and security mode
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  pg_get_function_result(p.oid) as return_type,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('ajm_register_device', 'ajm_submit_sync_operation')
order by p.proname;

-- 4) Realtime publication membership
select pubname, schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
  and tablename in ('ajm_devices', 'ajm_sync_operations')
order by tablename;

-- 5) Confirm the legacy snapshot table remains present and untouched structurally
select
  id,
  revision,
  updated_at,
  (payload is not null) as has_payload
from public.ajm_pos_database
where id = 'main';
