-- AJM Reborn POS — checkout compatibility verification
-- READ ONLY. This script does not modify transaction, product, or customer data.
-- Run only after the staged migrations have been applied to a staging project.

-- 1) Confirm the legacy AJM snapshot still exists and show only metadata.
select id, revision, updated_at, (payload is not null) as has_payload
from public.ajm_pos_database
where id = 'main';

-- 2) Confirm the snapshot contains the arrays used by the existing AJM app.
select
  jsonb_typeof(payload->'products') as products_type,
  jsonb_typeof(payload->'transactions') as transactions_type,
  jsonb_typeof(payload->'workOrders') as work_orders_type,
  jsonb_typeof(payload->'stockLogs') as stock_logs_type,
  jsonb_typeof(payload->'cashflows') as cashflows_type
from public.ajm_pos_database
where id = 'main';

-- Expected for initialized production data: all five values are 'array'.

-- 3) Inspect registered sale processor signature and security mode.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_process_sale';

-- 4) Inspect transaction ledger constraints relevant to idempotency.
select
  c.conname,
  pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'ajm_sales_ledger'
order by c.conname;

-- 5) Inspect RLS and policies for new multi-device tables.
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'ajm_devices',
    'ajm_sync_operations',
    'ajm_user_roles',
    'ajm_sales_ledger',
    'ajm_local_identity_links'
  )
  and c.relkind = 'r'
order by c.relname;

select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename in (
    'ajm_devices',
    'ajm_sync_operations',
    'ajm_user_roles',
    'ajm_sales_ledger',
    'ajm_local_identity_links'
  )
order by tablename, policyname;

-- 6) Report only counts; do not expose customer or transaction contents.
select
  jsonb_array_length(coalesce(payload->'products', '[]'::jsonb)) as product_count,
  jsonb_array_length(coalesce(payload->'transactions', '[]'::jsonb)) as transaction_count,
  jsonb_array_length(coalesce(payload->'workOrders', '[]'::jsonb)) as work_order_count,
  jsonb_array_length(coalesce(payload->'stockLogs', '[]'::jsonb)) as stock_log_count,
  jsonb_array_length(coalesce(payload->'cashflows', '[]'::jsonb)) as cashflow_count
from public.ajm_pos_database
where id = 'main';

-- This is structural verification only. It does not prove concurrency safety,
-- correct accounting, offline replay, receipt behavior, or printer compatibility.
-- Those require staged integration tests with separate authenticated devices.
