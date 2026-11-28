-- AJM Reborn POS — Phase 8: idempotent debt/DP collection
-- Staged additive migration. Does not change legacy transaction fields or tables.
-- Locks the authoritative snapshot and applies one collection exactly once.
-- Do not apply to production before staging and accounting regression tests.

begin;

create table if not exists public.ajm_business_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  device_key text not null references public.ajm_devices(device_key) on update cascade on delete restrict,
  operation_type text not null,
  reference_key text not null,
  result_data jsonb not null,
  created_at timestamptz not null default now(),
  constraint ajm_business_operations_type_check
    check (operation_type in ('debt.payment')),
  constraint ajm_business_operations_result_object
    check (jsonb_typeof(result_data) = 'object')
);

create index if not exists ajm_business_operations_user_created_idx
  on public.ajm_business_operations(user_id, created_at desc);

alter table public.ajm_business_operations enable row level security;

drop policy if exists "AJM users read own business operations" on public.ajm_business_operations;
create policy "AJM users read own business operations"
  on public.ajm_business_operations for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.ajm_business_operations to authenticated;

create or replace function public.ajm_apply_debt_payment(
  p_operation_id uuid,
  p_device_key text,
  p_invoice text,
  p_payment_id text,
  p_amount numeric,
  p_method text,
  p_cashier text,
  p_note text default null
)
returns table (
  result_status text,
  result_invoice text,
  result_revision bigint,
  result_message text,
  result_transaction jsonb
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
  v_transactions jsonb;
  v_transaction jsonb;
  v_updated_transaction jsonb;
  v_index bigint;
  v_total numeric;
  v_paid numeric;
  v_remaining numeric;
  v_new_paid numeric;
  v_new_remaining numeric;
  v_revision bigint;
  v_new_revision bigint;
  v_payment jsonb;
  v_invoice text := nullif(btrim(p_invoice), '');
  v_payment_id text := nullif(btrim(p_payment_id), '');
  v_method text := nullif(btrim(p_method), '');
  v_cashier text := nullif(btrim(p_cashier), '');
begin
  if v_user_id is null then
    return query select 'unauthorized', v_invoice, null::bigint,
      'Login Supabase diperlukan.', null::jsonb;
    return;
  end if;

  select r.app_role into v_role
  from public.ajm_user_roles r
  where r.user_id = v_user_id and r.is_active = true;

  if v_role is null then
    return query select 'role_not_configured', v_invoice, null::bigint,
      'Akun belum dipetakan ke peran Admin/Kasir.', null::jsonb;
    return;
  end if;

  if p_operation_id is null or p_device_key is null
     or v_invoice is null or length(v_invoice) > 120
     or v_payment_id is null or length(v_payment_id) > 120
     or p_amount is null or p_amount <= 0
     or v_method is null or length(v_method) > 80
     or v_cashier is null or length(v_cashier) > 120 then
    return query select 'invalid_request', v_invoice, null::bigint,
      'ID operasi, invoice, ID pembayaran, jumlah, metode, dan kasir wajib valid.', null::jsonb;
    return;
  end if;

  if not exists (
    select 1 from public.ajm_devices d
    where d.device_key = p_device_key and d.user_id = v_user_id and d.is_active = true
  ) then
    return query select 'device_not_registered', v_invoice, null::bigint,
      'Perangkat belum terdaftar atau sudah dinonaktifkan.', null::jsonb;
    return;
  end if;

  -- Serialize business operations against the shared legacy snapshot.
  select d.payload, d.revision
    into v_payload, v_revision
  from public.ajm_pos_database d
  where d.id = 'main'
  for update;

  if not found or v_payload is null then
    return query select 'database_not_initialized', v_invoice, null::bigint,
      'Snapshot utama AJM tidak ditemukan.', null::jsonb;
    return;
  end if;

  select o.* into v_existing
  from public.ajm_business_operations o
  where o.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key
       or v_existing.reference_key <> v_invoice then
      return query select 'unauthorized', v_invoice, null::bigint,
        'ID operasi sudah digunakan oleh operasi lain.', null::jsonb;
    else
      return query select 'already_applied', v_invoice,
        (v_existing.result_data->>'revision')::bigint,
        'Pembayaran ini sudah pernah diterapkan; tidak ada penambahan ulang.',
        v_existing.result_data->'transaction';
    end if;
    return;
  end if;

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi server tidak valid.', null::jsonb;
    return;
  end if;

  select t.value, t.ordinality - 1
    into v_transaction, v_index
  from jsonb_array_elements(v_transactions) with ordinality as t(value, ordinality)
  where t.value->>'invoice' = v_invoice
  limit 1;

  if not found then
    return query select 'invoice_not_found', v_invoice, v_revision,
      'Invoice piutang tidak ditemukan pada database server.', null::jsonb;
    return;
  end if;

  begin
    v_total := greatest(0, coalesce(nullif(v_transaction->>'total','')::numeric, 0));
    v_paid := greatest(0, coalesce(nullif(v_transaction->>'paidAmount','')::numeric, 0));
    v_remaining := greatest(0, coalesce(nullif(v_transaction->>'remainingDebt','')::numeric, 0));
  exception when others then
    return query select 'invalid_debt_data', v_invoice, v_revision,
      'Nilai total atau saldo piutang pada invoice tidak valid.', null::jsonb;
    return;
  end;

  -- Backward compatibility for legacy transactions without explicit payment fields.
  if not (v_transaction ? 'paidAmount') or not (v_transaction ? 'remainingDebt') then
    if coalesce(v_transaction->>'status','') = 'Piutang' then
      if coalesce(v_transaction->>'cashReceived','') ~ '^[0-9]+(\\.[0-9]+)?

  if v_remaining <= 0 then
    return query select 'already_settled', v_invoice, v_revision,
      'Invoice ini sudah lunas.', v_transaction;
    return;
  end if;

  if p_amount > v_remaining then
    return query select 'amount_exceeds_debt', v_invoice, v_revision,
      'Jumlah pembayaran melebihi sisa piutang server.', v_transaction;
    return;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_transaction->'debtPayments','[]'::jsonb)) as p(value)
    where p.value->>'id' = v_payment_id
  ) then
    return query select 'duplicate_payment_id', v_invoice, v_revision,
      'ID pembayaran sudah tercatat pada invoice ini.', v_transaction;
    return;
  end if;

  v_new_paid := v_paid + p_amount;
  v_new_remaining := greatest(0, v_total - v_new_paid);
  v_payment := jsonb_build_object(
    'id', v_payment_id,
    'date', clock_timestamp(),
    'amount', p_amount,
    'method', v_method,
    'cashier', v_cashier,
    'note', coalesce(nullif(btrim(p_note), ''), case when v_new_remaining = 0 then 'Pelunasan piutang' else 'Cicilan piutang' end)
  );

  v_updated_transaction := jsonb_set(
    coalesce(v_transaction, '{}'::jsonb),
    '{debtPayments}',
    coalesce(v_transaction->'debtPayments','[]'::jsonb) || jsonb_build_array(v_payment),
    true
  );
  v_updated_transaction := jsonb_set(v_updated_transaction, '{paidAmount}', to_jsonb(v_new_paid), true);
  v_updated_transaction := jsonb_set(v_updated_transaction, '{remainingDebt}', to_jsonb(v_new_remaining), true);
  v_updated_transaction := jsonb_set(
    v_updated_transaction, '{cashReceived}',
    to_jsonb(greatest(
      case when coalesce(v_transaction->>'cashReceived','') ~ '^[0-9]+(\\.[0-9]+)?
  );

  if v_new_remaining = 0 then
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Lunas'::text), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{paymentMethod}', to_jsonb(v_method), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{settledAt}', to_jsonb(clock_timestamp()), true);
  else
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Piutang'::text), true);
  end if;

  v_transactions := jsonb_set(
    v_transactions,
    array[v_index::text],
    v_updated_transaction,
    false
  );
  v_payload := jsonb_set(v_payload, '{transactions}', v_transactions, true);
  v_new_revision := coalesce(v_revision,0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_business_operations
    (operation_id, user_id, device_key, operation_type, reference_key, result_data)
  values
    (p_operation_id, v_user_id, p_device_key, 'debt.payment', v_invoice,
     jsonb_build_object('revision',v_new_revision,'transaction',v_updated_transaction));

  return query select 'applied', v_invoice, v_new_revision,
    'Pembayaran piutang berhasil dicatat pada database server.', v_updated_transaction;
end;
$function$;

revoke all on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) from public;
grant execute on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) to authenticated;

commit;

-- READ-ONLY verification:
-- select p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid)
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname='ajm_apply_debt_payment';
--
-- Staging tests required:
-- * partial payment; full settlement; repeated operation_id; duplicate payment_id;
-- * amount greater than server balance; simultaneous payments from two devices;
-- * verify existing transaction's items/customer/mechanic/commission fields remain intact.
 then
        v_paid := least(v_total, greatest(0, (v_transaction->>'cashReceived')::numeric));
      else
        v_paid := 0;
      end if;
      v_remaining := greatest(0, v_total - v_paid);
    else
      v_paid := v_total;
      v_remaining := 0;
    end if;
  end if;

  if v_transaction ? 'debtPayments'
     and jsonb_typeof(v_transaction->'debtPayments') <> 'array' then
    return query select 'invalid_debt_payments', v_invoice, v_revision,
      'Format riwayat pembayaran piutang pada invoice tidak valid.', v_transaction;
    return;
  end if;

  if v_remaining <= 0 then
    return query select 'already_settled', v_invoice, v_revision,
      'Invoice ini sudah lunas.', v_transaction;
    return;
  end if;

  if p_amount > v_remaining then
    return query select 'amount_exceeds_debt', v_invoice, v_revision,
      'Jumlah pembayaran melebihi sisa piutang server.', v_transaction;
    return;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_transaction->'debtPayments','[]'::jsonb)) as p(value)
    where p.value->>'id' = v_payment_id
  ) then
    return query select 'duplicate_payment_id', v_invoice, v_revision,
      'ID pembayaran sudah tercatat pada invoice ini.', v_transaction;
    return;
  end if;

  v_new_paid := v_paid + p_amount;
  v_new_remaining := greatest(0, v_total - v_new_paid);
  v_payment := jsonb_build_object(
    'id', v_payment_id,
    'date', clock_timestamp(),
    'amount', p_amount,
    'method', v_method,
    'cashier', v_cashier,
    'note', coalesce(nullif(btrim(p_note), ''), case when v_new_remaining = 0 then 'Pelunasan piutang' else 'Cicilan piutang' end)
  );

  v_updated_transaction := jsonb_set(
    coalesce(v_transaction, '{}'::jsonb),
    '{debtPayments}',
    coalesce(v_transaction->'debtPayments','[]'::jsonb) || jsonb_build_array(v_payment),
    true
  );
  v_updated_transaction := jsonb_set(v_updated_transaction, '{paidAmount}', to_jsonb(v_new_paid), true);
  v_updated_transaction := jsonb_set(v_updated_transaction, '{remainingDebt}', to_jsonb(v_new_remaining), true);
  v_updated_transaction := jsonb_set(
    v_updated_transaction, '{cashReceived}',
    to_jsonb(greatest(coalesce(nullif(v_transaction->>'cashReceived','')::numeric,0), v_new_paid)), true
  );

  if v_new_remaining = 0 then
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Lunas'::text), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{paymentMethod}', to_jsonb(v_method), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{settledAt}', to_jsonb(clock_timestamp()), true);
  else
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Piutang'::text), true);
  end if;

  v_transactions := jsonb_set(
    v_transactions,
    array[v_index::text],
    v_updated_transaction,
    false
  );
  v_payload := jsonb_set(v_payload, '{transactions}', v_transactions, true);
  v_new_revision := coalesce(v_revision,0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_business_operations
    (operation_id, user_id, device_key, operation_type, reference_key, result_data)
  values
    (p_operation_id, v_user_id, p_device_key, 'debt.payment', v_invoice,
     jsonb_build_object('revision',v_new_revision,'transaction',v_updated_transaction));

  return query select 'applied', v_invoice, v_new_revision,
    'Pembayaran piutang berhasil dicatat pada database server.', v_updated_transaction;
end;
$function$;

revoke all on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) from public;
grant execute on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) to authenticated;

commit;

-- READ-ONLY verification:
-- select p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid)
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname='ajm_apply_debt_payment';
--
-- Staging tests required:
-- * partial payment; full settlement; repeated operation_id; duplicate payment_id;
-- * amount greater than server balance; simultaneous payments from two devices;
-- * verify existing transaction's items/customer/mechanic/commission fields remain intact.

        then (v_transaction->>'cashReceived')::numeric else 0 end,
      v_new_paid
    )), true
  );

  if v_new_remaining = 0 then
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Lunas'::text), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{paymentMethod}', to_jsonb(v_method), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{settledAt}', to_jsonb(clock_timestamp()), true);
  else
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Piutang'::text), true);
  end if;

  v_transactions := jsonb_set(
    v_transactions,
    array[v_index::text],
    v_updated_transaction,
    false
  );
  v_payload := jsonb_set(v_payload, '{transactions}', v_transactions, true);
  v_new_revision := coalesce(v_revision,0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_business_operations
    (operation_id, user_id, device_key, operation_type, reference_key, result_data)
  values
    (p_operation_id, v_user_id, p_device_key, 'debt.payment', v_invoice,
     jsonb_build_object('revision',v_new_revision,'transaction',v_updated_transaction));

  return query select 'applied', v_invoice, v_new_revision,
    'Pembayaran piutang berhasil dicatat pada database server.', v_updated_transaction;
end;
$function$;

revoke all on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) from public;
grant execute on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) to authenticated;

commit;

-- READ-ONLY verification:
-- select p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid)
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname='ajm_apply_debt_payment';
--
-- Staging tests required:
-- * partial payment; full settlement; repeated operation_id; duplicate payment_id;
-- * amount greater than server balance; simultaneous payments from two devices;
-- * verify existing transaction's items/customer/mechanic/commission fields remain intact.
 then
        v_paid := least(v_total, greatest(0, (v_transaction->>'cashReceived')::numeric));
      else
        v_paid := 0;
      end if;
      v_remaining := greatest(0, v_total - v_paid);
    else
      v_paid := v_total;
      v_remaining := 0;
    end if;
  end if;

  if v_transaction ? 'debtPayments'
     and jsonb_typeof(v_transaction->'debtPayments') <> 'array' then
    return query select 'invalid_debt_payments', v_invoice, v_revision,
      'Format riwayat pembayaran piutang pada invoice tidak valid.', v_transaction;
    return;
  end if;

  if v_remaining <= 0 then
    return query select 'already_settled', v_invoice, v_revision,
      'Invoice ini sudah lunas.', v_transaction;
    return;
  end if;

  if p_amount > v_remaining then
    return query select 'amount_exceeds_debt', v_invoice, v_revision,
      'Jumlah pembayaran melebihi sisa piutang server.', v_transaction;
    return;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_transaction->'debtPayments','[]'::jsonb)) as p(value)
    where p.value->>'id' = v_payment_id
  ) then
    return query select 'duplicate_payment_id', v_invoice, v_revision,
      'ID pembayaran sudah tercatat pada invoice ini.', v_transaction;
    return;
  end if;

  v_new_paid := v_paid + p_amount;
  v_new_remaining := greatest(0, v_total - v_new_paid);
  v_payment := jsonb_build_object(
    'id', v_payment_id,
    'date', clock_timestamp(),
    'amount', p_amount,
    'method', v_method,
    'cashier', v_cashier,
    'note', coalesce(nullif(btrim(p_note), ''), case when v_new_remaining = 0 then 'Pelunasan piutang' else 'Cicilan piutang' end)
  );

  v_updated_transaction := jsonb_set(
    coalesce(v_transaction, '{}'::jsonb),
    '{debtPayments}',
    coalesce(v_transaction->'debtPayments','[]'::jsonb) || jsonb_build_array(v_payment),
    true
  );
  v_updated_transaction := jsonb_set(v_updated_transaction, '{paidAmount}', to_jsonb(v_new_paid), true);
  v_updated_transaction := jsonb_set(v_updated_transaction, '{remainingDebt}', to_jsonb(v_new_remaining), true);
  v_updated_transaction := jsonb_set(
    v_updated_transaction, '{cashReceived}',
    to_jsonb(greatest(coalesce(nullif(v_transaction->>'cashReceived','')::numeric,0), v_new_paid)), true
  );

  if v_new_remaining = 0 then
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Lunas'::text), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{paymentMethod}', to_jsonb(v_method), true);
    v_updated_transaction := jsonb_set(v_updated_transaction, '{settledAt}', to_jsonb(clock_timestamp()), true);
  else
    v_updated_transaction := jsonb_set(v_updated_transaction, '{status}', to_jsonb('Piutang'::text), true);
  end if;

  v_transactions := jsonb_set(
    v_transactions,
    array[v_index::text],
    v_updated_transaction,
    false
  );
  v_payload := jsonb_set(v_payload, '{transactions}', v_transactions, true);
  v_new_revision := coalesce(v_revision,0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_business_operations
    (operation_id, user_id, device_key, operation_type, reference_key, result_data)
  values
    (p_operation_id, v_user_id, p_device_key, 'debt.payment', v_invoice,
     jsonb_build_object('revision',v_new_revision,'transaction',v_updated_transaction));

  return query select 'applied', v_invoice, v_new_revision,
    'Pembayaran piutang berhasil dicatat pada database server.', v_updated_transaction;
end;
$function$;

revoke all on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) from public;
grant execute on function public.ajm_apply_debt_payment(uuid,text,text,text,numeric,text,text,text) to authenticated;

commit;

-- READ-ONLY verification:
-- select p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid)
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname='ajm_apply_debt_payment';
--
-- Staging tests required:
-- * partial payment; full settlement; repeated operation_id; duplicate payment_id;
-- * amount greater than server balance; simultaneous payments from two devices;
-- * verify existing transaction's items/customer/mechanic/commission fields remain intact.
