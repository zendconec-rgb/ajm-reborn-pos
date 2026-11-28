# AJM Reborn POS — checkout data contract

This document records behavior inspected in the current production `main/index.html`.
It is a compatibility contract for multi-device work; it is not a claim that cloud
checkout is already integrated.

## Existing checkout record

The current `processCheckout()` builds a transaction object with these fields:

- `invoice`, `date`, `plateMotor`
- `customerId`, `customerName`, `customerPhone`
- `mechanic`, `mechanicCommissionRate`, `cashier`
- `items` (deep copy of the cart), `subtotal`, `discount`, `tax`, `total`
- `paymentMethod`, `cashReceived`, `paidAmount`, `remainingDebt`, `change`
- `status` (`Piutang` or `Lunas`), `debtPayments`, `driveSynced`

Newly created transaction records now include a backward-compatible
`workOrderId` field (string ID or null), copied from `activeWorkOrderId`.
The local checkout still completes the work order after local persistence.
The staged `ajm_process_sale` RPC now validates the optional ID and completes the
matching work order in the same locked snapshot update as stock and transaction
posting. This server path is not wired into checkout yet; do not treat local
completion as server confirmation.

## Existing checkout side effects

Observed in `processCheckout()`:

1. For each cart line, find a product by `id`.
2. If the product category is not exactly `Jasa Servis`, decrement local `stock`
   by the cart quantity, currently clamped at zero.
3. If `activeWorkOrderId` resolves to a work order, set its status to `Selesai`.
4. Prepend the transaction to `transactions`.
5. Persist transactions, products, and work orders via `saveAllData()`.
6. Show the receipt, enqueue Google Drive sync, and clear the cart.

The server must not copy the local stock clamp behavior: a multi-device sale must
reject insufficient authoritative stock and keep the sale in a visible conflict
state rather than silently post an under-stocked sale.

## Financial interpretation

The checkout creates `debtPayments` only when the transaction has both an initial
payment and a remaining debt. That initial payment contains `id`, `date`, `amount`,
`method`, `cashier`, and `note`. The unpaid amount is represented by
`remainingDebt`; later collection appends another entry to `debtPayments` and
updates `paidAmount`, `remainingDebt`, `status`, and possibly `settledAt`.

Financial reports calculate revenue and receipts from `transactions` and their
payment breakdown. Cashflow entries are separately created by the cashflow form
with `id`, `date`, `type`, `amount`, and `note`. Therefore, automatically
creating a cashflow entry for every sale would change the current reporting model
and risks double-counting revenue. Do not do so without a deliberate reporting
migration and reconciliation.

Likewise, `stockLogs` are created by stock-import/opname workflows. The existing
checkout code does not append a stock log on sale. A cloud implementation must
preserve that behavior unless the product owner explicitly approves adding sale
movement records and updating all stock reports accordingly.

## Mechanic commission

Each checkout snapshots `mechanicCommissionRate` onto the transaction. Reports
calculate mechanic service totals and estimated commission from transaction items
and this snapshot. Preserve the snapshot; do not recalculate historical commission
using the mechanic's current setting.

## Required cloud sale invariants

- One `operation_id` maps to exactly one posted sale.
- One `invoice` maps to at most one posted sale.
- Replaying a posted operation returns its original transaction without another
  stock decrement, work-order completion, or financial effect.
- Product quantities are aggregated by product ID before stock validation.
- Service items are excluded from stock decrement only when they match the existing
  service-category rule; confirm all service category labels before rollout.
- Insufficient stock is a conflict, never a successful sale with stock clamped to zero.
- The full original transaction JSON is retained, including customer name, items,
  payment split, debtPayments, cashier, mechanic, and commission snapshot.
- Receipt printing occurs only after the server confirms `posted` or
  `already_posted` in cloud mode. An offline sale must remain visibly pending and
  must not be represented as cloud-posted.

## Gaps before production integration

1. Add optional `workOrderId` to newly created transaction records and pass it to
   the server RPC; verify the referenced work order belongs to the same snapshot.
2. Implement server-side update of the matching work order status in the same
   transaction as stock and transaction insertion.
3. Define a safe, user-visible conflict resolution flow for stock conflicts and
   duplicate invoice conflicts; never silently delete queued operations.
4. Implement idempotent debt collection updates. The existing local debt-payment
   flow is a separate mutation after the original sale and must not be lost.
5. Decide whether stock movement history should include sale-out entries. Current
   checkout does not write them, so this is a product/reporting decision.
6. Keep manual cashflow records separate from sale revenue unless accounting
   reports are redesigned and reconciled.
7. Validate service-category labels, fractional quantities, custom item prices,
   discounts, taxes, payment types, and refunds/cancellations against actual UI
   behavior before enabling server posting.

## Production safety

The multi-device development branch must remain separate from `main` until the
complete RPC contract, SQL migrations, browser client, and regression suite pass
against a staging database with two or three independent devices. Never run an
unverified migration against the live AJM database.
