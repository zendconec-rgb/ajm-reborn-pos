-- AJM Reborn POS — read-only Supabase schema diagnostic
-- Run this in Supabase Dashboard > SQL Editor on the EXISTING project.
-- It does not create, alter, delete, or update anything.
-- Copy the complete result sets back into the AJM Reborn POS conversation.

-- 1) Tables, columns, types, defaults, nullability
select
  table_schema,
  table_name,
  ordinal_position,
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
from information_schema.columns
where table_schema in ('public')
order by table_name, ordinal_position;

-- 2) Primary keys, unique constraints, foreign keys, check constraints
select
  ns.nspname as schema_name,
  tbl.relname as table_name,
  con.conname as constraint_name,
  case con.contype
    when 'p' then 'PRIMARY KEY'
    when 'u' then 'UNIQUE'
    when 'f' then 'FOREIGN KEY'
    when 'c' then 'CHECK'
    else con.contype::text
  end as constraint_type,
  pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
join pg_class tbl on tbl.oid = con.conrelid
join pg_namespace ns on ns.oid = tbl.relnamespace
where ns.nspname = 'public'
order by tbl.relname, con.contype, con.conname;

-- 3) RLS status per public table
select
  schemaname,
  tablename,
  rowsecurity as rls_enabled,
  (select count(*) from pg_policies p
    where p.schemaname = t.schemaname and p.tablename = t.tablename) as policy_count
from pg_tables t
where schemaname = 'public'
order by tablename;

-- 4) Existing RLS policies
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-- 5) Existing public functions/RPCs and their signatures
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments,
  pg_get_function_result(p.oid) as return_type,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as owner
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by p.proname, arguments;

-- 6) Realtime publication membership (which public tables are published)
select
  pubname,
  schemaname,
  tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by schemaname, tablename;

-- 7) Existing legacy AJM snapshot row metadata only (no business payload)
-- This helps confirm whether the old snapshot table is present and its revision.
select
  id,
  revision,
  updated_at,
  case when payload is null then false else true end as has_payload
from public.ajm_pos_database
where id = 'main';
