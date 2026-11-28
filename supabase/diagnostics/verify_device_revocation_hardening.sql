-- AJM Reborn POS — device revocation hardening verification
-- READ ONLY. Run after migration 20261128_005_device_revocation_hardening.sql.

-- 1) Authenticated clients must not be able to update device records directly.
select
  has_table_privilege('authenticated', 'public.ajm_devices', 'UPDATE')
    as authenticated_can_directly_update_devices;
-- Expected: false

-- 2) There must be no ordinary-user UPDATE policy on ajm_devices.
select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'ajm_devices'
  and cmd = 'UPDATE';
-- Expected: zero rows

-- 3) Registration RPC must be SECURITY DEFINER.
select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_register_device';
-- Expected: security_definer = true

-- 4) Admin-only device control RPC must remain available.
select
  p.proname,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_admin_set_device_active';
-- Expected: one row, security_definer = true

-- Do not test revocation by changing production device rows.
-- In staging, revoke a test device as Admin, then call ajm_register_device
-- while authenticated as that device owner. Expected error:
-- AJM_DEVICE_REVOKED_BY_ADMIN.
