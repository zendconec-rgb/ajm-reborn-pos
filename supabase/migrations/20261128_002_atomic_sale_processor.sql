-- AJM Reborn POS — Phase 2 atomic sale processor (corrected)
-- Staged migration. Do not apply in production before staging and full regression tests.
-- Preserves the existing ajm_pos_database JSON snapshot and its other sections.
-- This phase posts transaction + stock only; it is NOT yet the complete business ledger.

begin;

create table if not exists public.ajm_user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  app_role text not null check (app_role in ('Admin', 'Kasir')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ajm_sales_ledger (
  operation_id uuid primary key,
  invoice text not null unique,
  user_id uuid not null references auth.users(id) on delete restrict,
  device_key text not null references public.ajm_devices(device_key) on update cascade on delete restrict,
  transaction_data jsonb not null,
  posted_revision bigint not null,
  posted_at timestamptz not null default now(),
  constraint ajm_sales_ledger_invoice_nonempty check (length(trim(invoice)) between 1 and 120),
  constraint ajm_sales_ledger_transaction_object check (jsonb_typeof(transaction_data) = 'object')
);

create index if not exists ajm_sales_ledger_user_posted_idx
  on public.ajm_sales_ledger(user_id, posted_at desc);

alter table public.ajm_user_roles enable row level security;
alter table public.ajm_sales_ledger enable row level security;

drop policy if exists "AJM users read own role" on public.ajm_user_roles;
create policy "AJM users read own role"
  on public.ajm_user_roles for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "AJM users read own sales ledger" on public.ajm_sales_ledger;
create policy "AJM users read own sales ledger"
  on public.ajm_sales_ledger for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.ajm_user_roles to authenticated;
grant select on public.ajm_sales_ledger to authenticated;

create or replace function public.ajm_process_sale(
  p_operation_id uuid,
  p_device_key text,
  p_transaction jsonb
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
  v_invoice text;
  v_existing public.ajm_sales_ledger%rowtype;
  v_payload jsonb;
  v_products jsonb;
  v_transactions jsonb;
  v_item record;
  v_product jsonb;
  v_product_index bigint;
  v_stock numeric;
  v_category text;
  v_revision bigint;
  v_new_revision bigint;
  v_new_transaction jsonb;
  v_calc_subtotal numeric;
  v_subtotal numeric;
  v_discount numeric;
  v_tax numeric;
  v_total numeric;
  v_paid numeric;
  v_remaining numeric;
  v_cash_received numeric;
begin
  if v_user_id is null then
    return query select 'unauthorized', null::text, null::bigint, 'Login Supabase diperlukan.', null::jsonb;
    return;
  end if;

  select r.app_role into v_role
  from public.ajm_user_roles r
  where r.user_id = v_user_id and r.is_active = true;

  if v_role is null then
    return query select 'role_not_configured', null::text, null::bigint,
      'Akun belum dipetakan ke peran Admin/Kasir oleh administrator.', null::jsonb;
    return;
  end if;

  if p_operation_id is null or p_device_key is null
     or p_transaction is null or jsonb_typeof(p_transaction) <> 'object' then
    return query select 'invalid_request', null::text, null::bigint,
      'ID operasi, perangkat, dan objek transaksi wajib tersedia.', null::jsonb;
    return;
  end if;

  if not exists (
    select 1 from public.ajm_devices d
    where d.device_key = p_device_key
      and d.user_id = v_user_id
      and d.is_active = true
  ) then
    return query select 'device_not_registered', null::text, null::bigint,
      'Perangkat belum terdaftar atau sudah dinonaktifkan.', null::jsonb;
    return;
  end if;

  v_invoice := nullif(btrim(p_transaction->>'invoice'), '');
  if v_invoice is null or length(v_invoice) > 120 then
    return query select 'invalid_invoice', null::text, null::bigint,
      'Nomor invoice tidak valid.', null::jsonb;
    return;
  end if;

  if coalesce(jsonb_typeof(p_transaction->'items'), '') <> 'array'
     or jsonb_array_length(coalesce(p_transaction->'items', '[]'::jsonb)) = 0 then
    return query select 'invalid_items', v_invoice, null::bigint,
      'Transaksi harus memiliki minimal satu item.', null::jsonb;
    return;
  end if;

  -- Validate every line before any numeric cast. Only positive decimal quantities.
  if exists (
    select 1
    from jsonb_array_elements(p_transaction->'items') as item(value)
    where jsonb_typeof(item.value) <> 'object'
       or coalesce(item.value->>'id', '') = ''
       or case
            when coalesce(item.value->>'qty', '') ~ '^[0-9]+([.][0-9]+)?
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Validate line prices and financial arithmetic before stock mutation.
  -- Cart prices can be intentionally edited, so this checks internal consistency
  -- rather than forcing the current catalogue price.
  if exists (
    select 1
    from jsonb_array_elements(p_transaction->'items') as item(value)
    where case
            when coalesce(item.value->>'price', '') ~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    elsif v_existing.invoice <> v_invoice then
      return query select 'operation_id_conflict', v_existing.invoice, null::bigint,
        'ID operasi sudah terikat pada invoice lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'price')::numeric < 0
            else true
          end
  ) then
    return query select 'invalid_item_price', v_invoice, null::bigint,
      'Harga salah satu item tidak valid.', null::jsonb;
    return;
  end if;

  begin
    select coalesce(sum((item.value->>'price')::numeric * (item.value->>'qty')::numeric), 0)
      into v_calc_subtotal
    from jsonb_array_elements(p_transaction->'items') as item(value);

    if coalesce(p_transaction->>'subtotal','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'discount','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'tax','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'total','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'paidAmount','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'remainingDebt','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

       or coalesce(p_transaction->>'cashReceived','') !~ '^[0-9]+([.][0-9]+)?  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.
 then
      raise exception 'invalid financial fields';
    end if;

    v_subtotal := (p_transaction->>'subtotal')::numeric;
    v_discount := (p_transaction->>'discount')::numeric;
    v_tax := (p_transaction->>'tax')::numeric;
    v_total := (p_transaction->>'total')::numeric;
    v_paid := (p_transaction->>'paidAmount')::numeric;
    v_remaining := (p_transaction->>'remainingDebt')::numeric;
    v_cash_received := (p_transaction->>'cashReceived')::numeric;

    if v_subtotal < 0 or v_discount < 0 or v_tax < 0 or v_total <= 0
       or v_paid < 0 or v_remaining < 0 or v_cash_received < 0
       or v_discount > v_subtotal
       or abs(v_subtotal - v_calc_subtotal) > 0.01
       or abs(v_total - (v_subtotal - v_discount + v_tax)) > 0.01
       or abs(v_total - (v_paid + v_remaining)) > 0.01
       or v_paid > v_total then
      raise exception 'inconsistent financial fields';
    end if;
  exception when others then
    return query select 'invalid_financial_totals', v_invoice, null::bigint,
      'Subtotal, diskon, pajak, total, atau rincian pembayaran tidak konsisten.', null::jsonb;
    return;
  end;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, null::bigint,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Lock the legacy snapshot before checking idempotency. This serializes all
  -- sale calls and prevents concurrent duplicate operation IDs from racing.
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

  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id or v_existing.device_key <> p_device_key then
      return query select 'unauthorized', v_existing.invoice, null::bigint,
        'ID operasi ini sudah digunakan akun atau perangkat lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, v_revision,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Aggregate repeated cart lines so the same SKU cannot evade stock validation.
  for v_item in
    select item.value->>'id' as product_id,
           sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    select p.value, p.ordinality - 1
      into v_product, v_product_index
    from jsonb_array_elements(v_products) with ordinality as p(value, ordinality)
    where p.value->>'id' = v_item.product_id
    limit 1;

    if not found then
      return query select 'product_not_found', v_invoice, v_revision,
        'Produk ' || v_item.product_id || ' tidak ditemukan di katalog server.', null::jsonb;
      return;
    end if;

    v_category := coalesce(v_product->>'category', '');
    if v_category <> 'Jasa Servis' then
      begin
        v_stock := coalesce(nullif(v_product->>'stock', '')::numeric, 0);
      exception when others then
        return query select 'invalid_stock_value', v_invoice, v_revision,
          'Nilai stok produk ' || v_item.product_id || ' tidak valid.', null::jsonb;
        return;
      end;

      if v_stock < v_item.required_qty then
        return query select 'stock_conflict', v_invoice, v_revision,
          'Stok tidak mencukupi untuk produk ' || coalesce(v_product->>'name', v_item.product_id)
            || '. Stok server: ' || v_stock::text
            || ', kebutuhan: ' || v_item.required_qty::text || '.', null::jsonb;
        return;
      end if;

      v_products := jsonb_set(
        v_products,
        array[v_product_index::text, 'stock'],
        to_jsonb(v_stock - v_item.required_qty),
        true
      );
    end if;
  end loop;

  v_new_transaction := p_transaction || jsonb_build_object(
    'serverPostedAt', clock_timestamp(),
    'serverPostedBy', v_user_id,
    'syncStatus', 'posted'
  );

  v_transactions := coalesce(v_payload->'transactions', '[]'::jsonb);
  if jsonb_typeof(v_transactions) <> 'array' then
    return query select 'invalid_transaction_history', v_invoice, v_revision,
      'Format riwayat transaksi pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{transactions}',
    jsonb_build_array(v_new_transaction) || v_transactions, true);

  v_new_revision := coalesce(v_revision, 0) + 1;

  update public.ajm_pos_database
  set payload = v_payload,
      revision = v_new_revision,
      updated_at = now(),
      updated_by = v_user_id
  where id = 'main';

  insert into public.ajm_sales_ledger
    (operation_id, invoice, user_id, device_key, transaction_data, posted_revision)
  values
    (p_operation_id, v_invoice, v_user_id, p_device_key, v_new_transaction, v_new_revision);

  return query select 'posted', v_invoice, v_new_revision,
    'Transaksi dan stok berhasil dicatat pada snapshot server.', v_new_transaction;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- Bootstrap role mappings separately as project owner; use actual auth.users.id UUIDs.
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('AUTH_USER_UUID', 'Admin')
-- on conflict (user_id) do update set app_role=excluded.app_role, is_active=true, updated_at=now();
--
-- LIMITATION: this phase changes products.stock and appends transactions only.
-- It does not yet post stockLogs, cashflows, workOrders, debtPayments, or commissions.
-- Do not enable production checkout until those effects are included and tested.
