-- AJM Reborn POS — staged release structural audit
-- READ ONLY. Run in Supabase SQL Editor after applying migrations 001-007 to STAGING.
-- This script does not modify application data or schema.

-- 1) Required objects and RLS status.
with required(table_name) as (
  values
    ('ajm_pos_database'),
    ('ajm_devices'),
    ('ajm_sync_operations'),
    ('ajm_user_roles'),
    ('ajm_sales_ledger'),
    ('ajm_business_operations'),
    ('ajm_local_identity_links')
)
select r.table_name,
       (c.oid is not null) as exists,
       coalesce(c.relrowsecurity, false) as rls_enabled,
       coalesce(c.relforcerowsecurity, false) as rls_forced
from required r
left join pg_class c
  on c.relname = r.table_name
 and c.relnamespace = 'public'::regnamespace
 and c.relkind in ('r','p')
order by r.table_name;

-- 2) Required RPCs: security mode, signature, fixed search_path and execute grants.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosecdef as security_definer,
       p.proconfig as function_settings,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'ajm_register_device',
    'ajm_submit_sync_operation',
    'ajm_process_sale',
    'ajm_is_active_admin',
    'ajm_admin_set_user_role',
    'ajm_admin_set_device_active',
    'ajm_link_local_identity',
    'ajm_apply_debt_payment',
    'ajm_complete_work_order'
  )
order by p.proname, arguments;

-- 3) Policies on all AJM multi-device tables.
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in (
    'ajm_devices',
    'ajm_sync_operations',
    'ajm_user_roles',
    'ajm_sales_ledger',
    'ajm_business_operations',
    'ajm_local_identity_links'
  )
order by tablename, policyname;

-- 4) Direct table privileges that must remain constrained.
select
  has_table_privilege('authenticated', 'public.ajm_devices', 'UPDATE') as authenticated_can_update_devices,
  has_table_privilege('authenticated', 'public.ajm_user_roles', 'INSERT') as authenticated_can_insert_roles,
  has_table_privilege('authenticated', 'public.ajm_user_roles', 'UPDATE') as authenticated_can_update_roles,
  has_table_privilege('authenticated', 'public.ajm_sales_ledger', 'INSERT') as authenticated_can_insert_sales_ledger,
  has_table_privilege('authenticated', 'public.ajm_business_operations', 'INSERT') as authenticated_can_insert_business_operations;

-- Expected for the direct privileges above: all false.
-- Business writes must pass through the SECURITY DEFINER RPCs, not direct table writes.

-- 5) Idempotency constraints and business operation types.
select t.relname as table_name,
       c.conname,
       pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in ('ajm_sales_ledger','ajm_business_operations')
order by t.relname, c.conname;

-- 6) Realtime publication membership.
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
  and tablename in ('ajm_devices','ajm_sync_operations')
order by tablename;

-- 7) Operational counts only; no customer or financial payload is exposed.
select 'devices' as object_name, count(*)::bigint as row_count from public.ajm_devices
union all
select 'sync_operations', count(*)::bigint from public.ajm_sync_operations
union all
select 'sales_ledger', count(*)::bigint from public.ajm_sales_ledger
union all
select 'business_operations', count(*)::bigint from public.ajm_business_operations;

-- This is a structural audit, not a functional release approval.
-- Still required: PostgreSQL execution of migrations; isolated authenticated
-- two/three-device tests; browser integration tests; offline replay; duplicate
-- invoice/operation tests; stock conflict tests; debt/work-order tests; printer
-- tests; and full regression against a backup copy of the production snapshot.
