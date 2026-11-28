-- AJM Reborn POS — Phase 2 atomic sale processor on the legacy snapshot
-- Additive only: preserves public.ajm_pos_database and all existing JSON sections.
-- IMPORTANT:
--   1. Apply Phase 1 migration first.
--   2. Insert authenticated user UUIDs into ajm_user_roles before enabling sales.
--   3. Test in a staging Supabase project with a backup before production.
--   4. This RPC serializes sales by locking the single legacy snapshot row.
--      It is safe against concurrent stock decrements but is not the final
--      normalized high-throughput architecture.

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
  v_qty numeric;
  v_revision bigint;
  v_new_revision bigint;
  v_new_transaction jsonb;
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

  if p_operation_id is null or p_device_key is null or jsonb_typeof(p_transaction) <> 'object' then
    return query select 'invalid_request', null::text, null::bigint,
      'ID operasi, perangkat, dan objek transaksi wajib tersedia.', null::jsonb;
    return;
  end if;

  if not exists (
    select 1 from public.ajm_devices d
    where d.device_key = p_device_key and d.user_id = v_user_id and d.is_active = true
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

  -- Idempotency: a replay of the same operation returns the original receipt.
  select l.* into v_existing
  from public.ajm_sales_ledger l
  where l.operation_id = p_operation_id;

  if found then
    if v_existing.user_id <> v_user_id then
      return query select 'unauthorized', v_invoice, null::bigint,
        'Operasi ini dimiliki akun lain.', null::jsonb;
    else
      return query select 'already_posted', v_existing.invoice, v_existing.posted_revision,
        'Transaksi ini sudah pernah diproses; tidak ada pengurangan stok ulang.',
        v_existing.transaction_data;
    end if;
    return;
  end if;

  -- Serialize all sales against the existing authoritative snapshot.
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

  if exists (select 1 from public.ajm_sales_ledger l where l.invoice = v_invoice) then
    return query select 'duplicate_invoice', v_invoice, null::bigint,
      'Nomor invoice sudah digunakan transaksi lain. Buat invoice baru sebelum mengirim ulang.', null::jsonb;
    return;
  end if;

  v_products := coalesce(v_payload->'products', '[]'::jsonb);
  if jsonb_typeof(v_products) <> 'array' then
    return query select 'invalid_catalog', v_invoice, v_revision,
      'Format katalog produk pada snapshot tidak valid.', null::jsonb;
    return;
  end if;

  -- Reject malformed item identifiers/quantities before numeric casts.
  if exists (
    select 1
    from jsonb_array_elements(p_transaction->'items') as item(value)
    where coalesce(item.value->>'id', '') = ''
       or case
            when coalesce(item.value->>'qty', '') ~ '^[0-9]+([.][0-9]+)?
    select
      item.value->>'id' as product_id,
      sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    if v_item.product_id is null or v_item.product_id = ''
       or v_item.required_qty is null or v_item.required_qty <= 0 then
      return query select 'invalid_item', v_invoice, v_revision,
        'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
      return;
    end if;

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

  -- The server assigns the authoritative posting timestamp.
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
  v_payload := jsonb_set(v_payload, '{transactions}', jsonb_build_array(v_new_transaction) || v_transactions, true);
  v_new_revision := v_revision + 1;

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
    'Transaksi berhasil diproses dan stok server diperbarui.', v_new_transaction;

exception
  when unique_violation then
    -- Handles a concurrent replay/duplicate invoice even if a caller races.
    return query select 'duplicate_or_replayed', v_invoice, null::bigint,
      'Invoice atau ID operasi sudah pernah digunakan. Periksa riwayat sebelum mencoba lagi.', null::jsonb;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- ADMIN SETUP (run separately, replacing UUID with the real Supabase Auth user UUID):
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('00000000-0000-0000-0000-000000000000', 'Admin')
-- on conflict (user_id) do update set app_role = excluded.app_role, is_active = true, updated_at = now();
--
-- KASIR SETUP:
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('00000000-0000-0000-0000-000000000000', 'Kasir')
-- on conflict (user_id) do update set app_role = excluded.app_role, is_active = true, updated_at = now();
--
-- NOTE: this phase serializes against the legacy JSON snapshot row. It deliberately
-- rejects insufficient stock rather than clamping stock to zero. A conflict must
-- be shown to the cashier/admin and resolved; never silently discard the offline sale.

              then (item.value->>'qty')::numeric <= 0
            else true
          end
  ) then
    return query select 'invalid_item', v_invoice, v_revision,
      'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
    return;
  end if;

  -- Validate quantities and aggregate repeated lines for the same product.
  for v_item in
    select
      item.value->>'id' as product_id,
      sum((item.value->>'qty')::numeric) as required_qty
    from jsonb_array_elements(p_transaction->'items') as item(value)
    group by item.value->>'id'
  loop
    if v_item.product_id is null or v_item.product_id = ''
       or v_item.required_qty is null or v_item.required_qty <= 0 then
      return query select 'invalid_item', v_invoice, v_revision,
        'Item transaksi memiliki ID atau jumlah yang tidak valid.', null::jsonb;
      return;
    end if;

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

  -- The server assigns the authoritative posting timestamp.
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
  v_payload := jsonb_set(v_payload, '{transactions}', jsonb_build_array(v_new_transaction) || v_transactions, true);
  v_new_revision := v_revision + 1;

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
    'Transaksi berhasil diproses dan stok server diperbarui.', v_new_transaction;

exception
  when unique_violation then
    -- Handles a concurrent replay/duplicate invoice even if a caller races.
    return query select 'duplicate_or_replayed', v_invoice, null::bigint,
      'Invoice atau ID operasi sudah pernah digunakan. Periksa riwayat sebelum mencoba lagi.', null::jsonb;
end;
$function$;

revoke all on function public.ajm_process_sale(uuid, text, jsonb) from public;
grant execute on function public.ajm_process_sale(uuid, text, jsonb) to authenticated;

commit;

-- ADMIN SETUP (run separately, replacing UUID with the real Supabase Auth user UUID):
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('00000000-0000-0000-0000-000000000000', 'Admin')
-- on conflict (user_id) do update set app_role = excluded.app_role, is_active = true, updated_at = now();
--
-- KASIR SETUP:
-- insert into public.ajm_user_roles(user_id, app_role)
-- values ('00000000-0000-0000-0000-000000000000', 'Kasir')
-- on conflict (user_id) do update set app_role = excluded.app_role, is_active = true, updated_at = now();
--
-- NOTE: this phase serializes against the legacy JSON snapshot row. It deliberately
-- rejects insufficient stock rather than clamping stock to zero. A conflict must
-- be shown to the cashier/admin and resolved; never silently discard the offline sale.
