-- AJM Reborn POS — Phase 2 atomic sale processor verification
-- Read-only. Run after applying migration 20261128_002_atomic_sale_processor.sql.

-- 1) Role mappings (UUIDs only; no personal data beyond auth user IDs)
select user_id, app_role, is_active, created_at, updated_at
from public.ajm_user_roles
order by created_at;

-- 2) Atomic sale RPC registration
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  pg_get_function_result(p.oid) as return_type,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_process_sale';

-- 3) New table RLS
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('ajm_user_roles', 'ajm_sales_ledger')
  and c.relkind = 'r'
order by c.relname;

-- 4) New RLS policies
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('ajm_user_roles', 'ajm_sales_ledger')
order by tablename, policyname;

-- 5) Confirm optional work-order handling is included in the atomic sale RPC.
select
  position('workOrderId' in pg_get_functiondef(p.oid)) > 0 as supports_work_order_id,
  position('work_order_conflict' in pg_get_functiondef(p.oid)) > 0 as detects_work_order_conflict,
  position('completedInvoice' in pg_get_functiondef(p.oid)) > 0 as records_completion_invoice
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_process_sale';

-- 6) Legacy snapshot still exists; only metadata is shown
select id, revision, updated_at, (payload is not null) as has_payload
from public.ajm_pos_database
where id = 'main';
