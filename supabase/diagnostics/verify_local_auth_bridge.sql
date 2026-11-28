-- AJM Reborn POS — Phase 4 local identity bridge verification
-- Read-only. Run after applying 20261128_004_local_auth_bridge.sql.

select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'ajm_link_local_identity';

select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'ajm_local_identity_links'
  and c.relkind = 'r';

select
  tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'ajm_local_identity_links';

-- Show only the current user's mapping when run from an authenticated session.
select local_user_id, auth_user_id, local_username, local_role, linked_at, last_verified_at
from public.ajm_local_identity_links
where auth_user_id = auth.uid();
