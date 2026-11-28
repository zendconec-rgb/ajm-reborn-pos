-- AJM Reborn POS — work-order completion verification
-- READ ONLY. Run after migrations 006 and 007 in a staging database.

select p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid) as arguments,
       p.proconfig
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='ajm_complete_work_order';

select c.conname, pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid=c.conrelid
join pg_namespace n on n.oid=t.relnamespace
where n.nspname='public' and t.relname='ajm_business_operations'
order by c.conname;

select c.relname, c.relrowsecurity
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='ajm_business_operations';

select tablename, policyname, cmd, roles
from pg_policies
where schemaname='public' and tablename='ajm_business_operations';

-- Functional staging tests (use disposable work orders):
-- 1. Menunggu -> Selesai returns 'completed' and increments revision once.
-- 2. Replay identical operation_id returns 'already_completed'; no second revision.
-- 3. Dikerjakan -> Selesai succeeds.
-- 4. Missing ID returns 'work_order_not_found'.
-- 5. Unknown status returns 'invalid_work_order_status'.
-- 6. Reuse operation_id for a different work order is rejected.
-- 7. Verify other work orders and every unrelated snapshot key are unchanged.
