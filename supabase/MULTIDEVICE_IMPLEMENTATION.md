# AJM Reborn POS — multi-device client foundation

This branch is a staged implementation. The production app continues to use the existing
legacy snapshot table `public.ajm_pos_database` until the transaction processor and UI
integration have been implemented and tested.

## Files

- `supabase/diagnostics/ajm_multidevice_readonly_diagnostic.sql`: read-only schema audit.
- `supabase/migrations/20261128_001_multidevice_foundation.sql`: additive device registry
  and idempotent operation inbox.
- `assets/js/ajm-multidevice-client.js`: IndexedDB device identity + durable outbox client.

## Current scope

The client module provides:
- stable per-browser device identity in IndexedDB;
- Supabase Auth-bound device registration through `ajm_register_device`;
- durable operation queue in IndexedDB;
- sequential delivery through `ajm_submit_sync_operation`;
- idempotency using operation UUIDs;
- retry preservation and a blocked state for auth/validation/permission errors.

## Important: not yet checkout-enabled

The module is deliberately not injected into `index.html` and does not intercept
existing checkout/save logic. Do not enqueue sales from the app until the next phase
implements and tests the server-side transaction processor, stock row locking,
duplicate invoice protection, conflict handling, and a cashier/admin recovery UI.

The current migration only stores operation envelopes in `ajm_sync_operations`.
It does NOT apply them to stock, cashflows, work orders, or the legacy JSON snapshot.
Therefore a successful outbox submission is an acknowledged inbox receipt, not proof
that a sale has been posted to the business ledger.

## Required next phase

1. Define relational transaction, transaction-item, stock, and audit tables based on
   the app's actual data model.
2. Map authenticated Supabase users to the existing Admin/Kasir role model.
3. Implement a SECURITY DEFINER RPC with a fixed search_path, strict authorization,
   idempotency, invoice uniqueness, stock locking, and explicit stock-conflict results.
4. Add client integration only after the RPC contract and SQL tests are complete.
5. Test two concurrent devices, offline replay, repeated operation IDs, disabled devices,
   role restrictions, and stock conflicts before enabling production.

## Apply migration

Only apply the SQL migration after taking a Supabase backup and reviewing it. The
migration is additive and intentionally leaves `ajm_pos_database` untouched, but any
production schema change should still be tested in a staging project first.

## Phase 2 — atomic sale posting (staged; not deployed)

- `supabase/migrations/20261128_002_atomic_sale_processor.sql` adds
  `ajm_user_roles`, `ajm_sales_ledger`, and the `ajm_process_sale` RPC.
- The RPC checks authenticated user role and registered device, locks the legacy
  `ajm_pos_database` row, validates item quantities and available stock, decrements
  stock and appends the sale to the existing JSON transaction history in one database
  transaction, and records an operation UUID + unique invoice for idempotency.
- Insufficient stock is returned as `stock_conflict`; the server does not clamp stock
  to zero or silently discard the sale.
- Both Admin and Kasir are currently allowed to submit a sale. Other privileged
  operations (settings, user management, stock adjustments) are not exposed by this RPC.
- Auth user IDs must be explicitly mapped in `ajm_user_roles` by a trusted project
  administrator. No role is inferred from the local-only AJM user list.

The IndexedDB client now has a `queueSale(transaction)` helper and dispatches
`sale.create` queue items to `ajm_process_sale`. This is still a development module:
it is not loaded by `index.html`, and no existing checkout handler has been modified.

### Known validation boundary

The RPC validates product existence, positive quantities, and stock availability.
Before production enablement, the next hardening pass must validate price/discount/tax
rules against the intended Admin/Kasir permissions, reconcile custom cart price edits,
and test all existing sale variants (service jobs, debt/DP, cash, transfer, e-wallet,
work-order completion, and receipts). The current RPC preserves the supplied transaction
JSON and should not yet be treated as a production-ready financial ledger.

## Phase 3 — Admin-managed roles and device revocation (staged; not deployed)

- `supabase/migrations/20261128_003_admin_role_management.sql` adds a secure
  active-Admin helper, an Admin-only role assignment RPC, and an Admin-only device
  activation/revocation RPC.
- Admins can be granted access to view all role mappings and the sales ledger.
  Ordinary users retain their own role and own-sale visibility.
- The first Admin must be bootstrapped by the Supabase project owner using the real
  Supabase Auth UUID. Do not map a local-only username or password.
- The role policies use a SECURITY DEFINER helper with an empty search_path to avoid
  recursive RLS evaluation. RPCs are not exposed to anon/public.
- Device revocation prevents future registration/operation submissions from that device.

## Important compatibility boundary

The existing HTML uses its own local user list and local password matching. It is
not yet bound to Supabase Auth identities. Therefore a local Admin/Kasir login is
not, by itself, proof of server authorization. The app must complete Supabase Auth
sign-in and obtain a valid session before calling these RPCs.

## Remaining before production

- Replace/bridge local authentication with Supabase Auth without exposing local
  plaintext passwords or breaking existing accounts.
- Map each Auth UUID to Admin/Kasir with the trusted Admin workflow.
- Update the app checkout flow to queue the exact transaction object and only mark it
  cloud-posted after `ajm_process_sale` returns `posted` or `already_posted`.
- Resolve invoice generation collisions across devices. Existing invoice generation
  based on local transaction count can collide when multiple devices work offline.
- Reconcile stockLogs, cashflows, work-order completion, debt/DP, and any post-sale
  side effects as part of the same server-side operation or a compensating workflow.
- Build a cashier-visible conflict screen and admin resolution workflow.

## Phase 4 — local AJM identity bridge (staged; not deployed)

- `supabase/migrations/20261128_004_local_auth_bridge.sql` adds
  `ajm_local_identity_links` and `ajm_link_local_identity`.
- The currently deployed HTML has a local username/password login and a separate
  Supabase Auth email/password connection in Settings. The bridge allows the
  authenticated Supabase user to associate with the already-authenticated local
  AJM account ID, but only when the server-side role matches the local role.
- Every operator must have an individual Supabase Auth user and matching server role.
  Sharing one cloud Admin account across multiple local cashiers is not safe.
- The module exposes `linkLocalIdentity(localUser)`; it is not called automatically
  by the production HTML yet. The app must explicitly connect Supabase Auth, then
  call this method after local login and handle mismatch errors before enabling
  cloud transaction actions.
- This does not migrate local passwords into Supabase and does not grant permissions
  based on client-provided roles; the server role in `ajm_user_roles` is authoritative.

## Current production integration status

The production `index.html` remains unchanged. The existing checkout currently
creates invoice numbers using the local transaction count, decrements local stock,
writes the local JSON state, and prints the receipt immediately. Directly replacing
this flow before a staged test would risk invoice collisions, inconsistent work-order
and cashflow updates, and loss of receipt workflow. Therefore the cloud queue module
and SQL processors remain staged until the full checkout transaction contract is
validated.

## Phase 5 — offline-safe invoice identity (client helper; staged)

The multi-device client now exposes `createOfflineInvoice(date)`. It retains the
familiar `INV-YYYYMMDD` prefix and appends a stable device fragment plus a random
suffix. This avoids relying on `transactions.length + 1`, which can collide when
multiple devices create invoices offline.

This helper is not yet wired into the production checkout. Existing invoice formats
remain unchanged until receipt, search, export, and workshop flows are regression-tested.
The server's unique invoice constraint remains the final collision guard.


## Phase 6 — device revocation hardening (staged; not deployed)

A security review found that ordinary authenticated users had direct UPDATE access
on their own device rows, and the earlier registration RPC could reactivate an
existing device key. That would weaken Admin device revocation. The hardening migration:

- removes direct authenticated UPDATE permission and the ordinary-user UPDATE policy
  on `ajm_devices`;
- changes `ajm_register_device` to SECURITY DEFINER with an empty search_path;
- allows an active owner to refresh only device metadata;
- rejects an existing inactive device with `AJM_DEVICE_REVOKED_BY_ADMIN` instead
  of reactivating it;
- preserves all device rows and operation history.

Files:
- `supabase/migrations/20261128_005_device_revocation_hardening.sql`
- `supabase/diagnostics/verify_device_revocation_hardening.sql`

This is still staged on the development branch. It has not been run against Supabase.
Run the read-only verification after applying it in a staging project. Production
migration and end-to-end testing remain blocked until the complete sale side effects
(stock logs, cashflows, work orders, debt/DP, commissions) are handled atomically.


## Phase 7 — SQL and offline-client correction (staged; not deployed)

A source review identified malformed SQL in the initial Phase 2 migration and literal
escape sequences in the browser client output. The Phase 2 migration has been rewritten
with valid quantity validation, aggregate validation for repeated SKU lines, snapshot
row serialization before idempotency lookup, and an explicit limitation statement.
The client now has corrected line breaks and publicly exposes the offline invoice,
sale queue, and retry helpers that were implemented but not exported.

This correction is a source-level repair only. It has not been executed by PostgreSQL
or validated in a browser runtime. Before production use, run migrations in a staging
Supabase project and test with two authenticated users/devices, repeated operation IDs,
duplicate invoices, insufficient stock, offline replay, and all transaction side effects.

**Still not implemented in this phase:** atomic posting of stockLogs, cashflows,
workOrders, debtPayments, mechanic commissions, and corresponding reversal/refund flows.
The production `index.html` remains unchanged and checkout is not cloud-enabled.


## Phase 8 — atomic debt/DP collection RPC (staged; not deployed)

Added `supabase/migrations/20261128_006_atomic_debt_payment.sql` and the
read-only structural verifier `supabase/diagnostics/verify_atomic_debt_payment.sql`.

The new `ajm_apply_debt_payment` RPC:

- requires an authenticated user with an active Admin/Kasir server role and an
  active registered device;
- serializes changes by locking the existing AJM snapshot row;
- applies a partial or final debt payment to the matching invoice;
- appends the legacy-compatible `debtPayments` entry and updates
  `paidAmount`, `remainingDebt`, `cashReceived`, `status`, and `settledAt`
  when fully settled;
- records an operation UUID in a separate unique operation ledger so retrying
  the same request cannot add the payment twice;
- rejects overpayment, duplicate payment IDs, invalid invoice/payment data, and
  malformed legacy debt-payment arrays;
- leaves customer, item, mechanic, commission, stock, and cashflow data untouched.

No automatic cashflow row is created. The existing AJM reports derive transaction
receipts from transaction payment fields and debtPayments; adding a second cashflow
entry for the same receipt could double-count revenue.

**Not yet wired into the browser app:** the local debt-payment form still follows
the current local persistence/Drive path. The new RPC has not been executed in
PostgreSQL or functionally tested. Do not enable it in production until staging
tests cover partial/full settlement, duplicate replay, overpayment, concurrent
collections from separate devices, and preservation of historical invoice fields.

Work-order completion still needs a transaction-safe server path. The current
sale processor has not yet been changed to include `workOrderId`; therefore the
existing local work-order completion must not be considered cloud-atomic.


## Client outbox safety correction — generic inbox acceptance is not completion

The IndexedDB outbox client now distinguishes a server inbox acknowledgement from a
completed business operation. For non-sale operations sent through
`ajm_submit_sync_operation`, an acknowledgement with status `pending` is retained
locally as `submitted`; it is no longer deleted or counted as a completed operation.
The client exposes this count and server receipt time through `getStatus()`.

This prevents silent data loss: the generic RPC is only an append-only inbox and
does not execute debt payments, work-order transitions, or other business effects.
Only a dedicated processor may safely mark such an operation `processed` and allow
the client to remove it. A submitted item currently requires a later processor/status
reconciliation path; it is intentionally not auto-resubmitted on every flush.


## Phase 9 — atomic work-order completion and client dispatch

Added `supabase/migrations/20261128_007_atomic_work_order_completion.sql`
and the read-only verifier
`supabase/diagnostics/verify_atomic_work_order_completion.sql`.

The `ajm_complete_work_order` RPC checks the authenticated Admin/Kasir role,
active device, existing work-order ID and allowed current status. It locks the
shared snapshot, changes only the matching work order to `Selesai`, records
completion metadata, increments the snapshot revision, and stores the operation
UUID in the business-operation ledger for safe retries.

The IndexedDB client now exports `queueDebtPayment()` and
`queueWorkOrderCompletion()`, and routes those operation types to their
dedicated server RPCs. It removes a queued item only after an explicit successful
business result. Conflicts and validation failures remain visible in the local
outbox.

**Important integration boundary:** these queue APIs are now available in the
client module, but the production checkout and debt-payment form in `index.html`
are deliberately not wired to them. In particular, checkout currently completes
a work order locally before server confirmation, and the sale transaction does
not persist `workOrderId`. The app must not be considered multi-device-ready
until the UI uses these APIs with rollback/reconciliation behavior and the sale
RPC handles transaction + work-order completion atomically.
