-- AJM Reborn POS — atomic debt payment RPC verification
-- READ ONLY. Run after migration 20261128_006_atomic_debt_payment.sql in staging.

-- 1) RPC signature and security mode.
select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_apply_debt_payment';

-- Expected: one row, security_definer=true, search_path empty.

-- 2) Operation ledger RLS and policies.
select c.relname, c.relrowsecurity
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'ajm_business_operations'
  and c.relkind = 'r';

select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename = 'ajm_business_operations';

-- 3) Idempotency and operation-type constraints.
select
  c.conname,
  pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'ajm_business_operations'
order by c.conname;

-- 4) Count only; do not expose customer/financial data.
select count(*) as recorded_business_operations
from public.ajm_business_operations;

-- Functional tests require a dedicated staging invoice and two authenticated devices.
-- A. Submit a partial amount; expect result_status='applied', debt balance reduced.
-- B. Replay the same operation_id; expect 'already_applied', no second payment.
-- C. Submit a new operation_id with same payment_id; expect 'duplicate_payment_id'.
-- D. Submit amount above current remainingDebt; expect 'amount_exceeds_debt'.
-- E. Submit final exact amount; expect status='Lunas' and remainingDebt=0.
-- F. Concurrent payments whose sum exceeds balance: only valid serialized amount
--    should apply; later request must receive amount_exceeds_debt.
-- G. Compare invoice items/customer/mechanic/commission fields before and after.
-- H. Confirm cashflows is unchanged: the current AJM model reports receipts from
--    transactions/debtPayments; a new cashflow row would risk double counting.
