-- AJM Reborn POS — Phase 9: idempotent work-order completion
-- Additive and staged. Does not change local production app or execute automatically.
-- Uses the existing JSON snapshot and shared business-operation idempotency ledger.

begin;

create or replace function public.ajm_complete_work_order(
  p_operation_id uuid,
  p_device_key text,
  p_work_order_id text,
  p_completed_by text default null
)
returns table (
  result_status text,
  result_work_order_id text,
  result_revision bigint,
  result_message text,
  result_work_order jsonb
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_existing public.ajm_business_operations%rowtype;
  v_payload jsonb;
  v_work_orders jsonb;
  v_work_order jsonb;
  v_updated_work_order jsonb;
  v_index bigint;
  v_revision bigint;
  v_new_revision bigint;
  v_work_order_id text := nullif(btrim(p_work_order_id), '');
begin
  if v_user_id is null then
    return query select 'unauthorized', v_work_order_id, null::bigint,
      'Login Supabase diperlukan.', null::jsonb;
    return;
  end if;

  select r.app_role into v_role
  from public.ajm_user_roles r
  where r.user_id = v_user_id and r.is_active = true;

  if v_role is null then
    return query select 'role_not_configured', v_work_order_id, null::bigint,
      'Akun belum dipetakan ke peran Admin/Kasir.', null::jsonb;
    return;
  end if;

  if p_operation_id is null or p_device_key is null
     or v_work_order_id is null or length(v_work_order_id) > 160
     or length(coalesce(p_completed_by,'')) > 120 then
    return query select 'invalid_request', v_work_order_id, null::bigint,
      'ID operasi, perangkat, dan ID work order wajib valid.', null::jsonb;
    return;
  end if;

  if not exists (
    select 1 from public.ajm_devices d
    where d.device_key = p_device_key and d.user_id = v_user_id and d.is_active = true
  ) then
    return query select 'device_not_registered', v_work_order_id, null::bigint,
      'Perangkat belum terdaftar atau sudah dinonaktifkan.', null::jsonb;
    return;
  end if;

  select d.payload, d.revision into v_payload, v_revision
  from public.ajm_pos_database d
  where d.id = 'main'
  for update;

  if not found or v_payload is null then
    return query select 'database_not_initialized', v_work_order_id, null::bigint,
      'Snapshot utama AJM tidak ditemukan.', null::jsonb;
    return;
  end if;

  select o.* into v_existing
  from public.ajm_business_operations o
  where o.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key
       or v_existing.reference_key <> v_work_order_id
       or v_existing.operation_type <> 'workorder.complete' then
      return query select 'unauthorized', v_work_order_id, null::bigint,
        'ID operasi sudah digunakan untuk operasi lain.', null::jsonb;
    else
      return query select 'already_completed', v_work_order_id,
        (v_existing.result_data->>'revision')::bigint,
        'Work order ini sudah diproses; tidak ada perubahan ganda.',
        v_existing.result_data->'work_order';
    end if;
    return;
  end if;

  v_work_orders := coalesce(v_payload->'workOrders','[]'::jsonb);
  if jsonb_typeof(v_work_orders) <> 'array' then
    return query select 'invalid_work_order_history', v_work_order_id, v_revision,
      'Format antrean work order pada server tidak valid.', null::jsonb;
    return;
  end if;

  select w.value, w.ordinality - 1 into v_work_order, v_index
  from jsonb_array_elements(v_work_orders) with ordinality as w(value, ordinality)
  where w.value->>'id' = v_work_order_id
  limit 1;

  if not found then
    return query select 'work_order_not_found', v_work_order_id, v_revision,
      'Work order tidak ditemukan pada database server.', null::jsonb;
    return;
  end if;

  if coalesce(v_work_order->>'status','') = 'Selesai' then
    return query select 'already_completed', v_work_order_id, v_revision,
      'Work order sudah berstatus Selesai.', v_work_order;
    return;
  end if;

  if coalesce(v_work_order->>'status','') not in ('Menunggu','Dikerjakan') then
    return query select 'invalid_work_order_status', v_work_order_id, v_revision,
      'Status work order tidak mengizinkan penyelesaian.', v_work_order;
    return;
  end if;

  v_updated_work_order := jsonb_set(v_work_order, '{status}', to_jsonb('Selesai'::text), true);
  v_updated_work_order := jsonb_set(v_updated_work_order, '{completedAt}', to_jsonb(clock_timestamp()), true);
  if nullif(btrim(coalesce(p_completed_by,'')),'') is not null then
    v_updated_work_order := jsonb_set(v_updated_work_order, '{completedBy}', to_jsonb(btrim(p_completed_by)), true);
  end if;

  v_work_orders := jsonb_set(v_work_orders, array[v_index::text], v_updated_work_order, false);
  v_payload := jsonb_set(v_payload, '{workOrders}', v_work_orders, true);
  v_new_revision := coalesce(v_revision,0) + 1;

  update public.ajm_pos_database
  set payload = v_payload, revision = v_new_revision, updated_at = now(), updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_business_operations
    (operation_id,user_id,device_key,operation_type,reference_key,result_data)
  values
    (p_operation_id,v_user_id,p_device_key,'workorder.complete',v_work_order_id,
     jsonb_build_object('revision',v_new_revision,'work_order',v_updated_work_order));

  return query select 'completed', v_work_order_id, v_new_revision,
    'Work order berhasil ditandai selesai pada database server.', v_updated_work_order;
end;
$function$;

revoke all on function public.ajm_complete_work_order(uuid,text,text,text) from public;
grant execute on function public.ajm_complete_work_order(uuid,text,text,text) to authenticated;

-- Expand the operation ledger's allowed types without rewriting historical rows.
alter table public.ajm_business_operations
  drop constraint if exists ajm_business_operations_type_check;
alter table public.ajm_business_operations
  add constraint ajm_business_operations_type_check
  check (operation_type in ('debt.payment','workorder.complete'));

commit;

-- Staging tests: successful completion; replay same operation ID; duplicate ID
-- against another work order; missing work order; invalid status; concurrent calls.
-- Verify all unrelated workOrders and all other snapshot sections remain unchanged.
