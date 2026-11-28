-- AJM Reborn POS — Phase 3 Admin role/device controls verification
-- Read-only. Run after applying 20261128_003_admin_role_management.sql.

-- 1) Security helper and admin RPCs
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'ajm_is_active_admin',
    'ajm_admin_set_user_role',
    'ajm_admin_set_device_active'
  )
order by p.proname;

-- 2) Role/device table RLS policies
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('ajm_user_roles', 'ajm_devices', 'ajm_sales_ledger')
order by tablename, policyname;

-- 3) Role assignments (user UUID + role only)
select user_id, app_role, is_active
from public.ajm_user_roles
order by created_at;

-- 4) Device registry (device key/name and account UUID)
select device_key, user_id, device_name, is_active, created_at, last_seen_at
from public.ajm_devices
order by created_at;
