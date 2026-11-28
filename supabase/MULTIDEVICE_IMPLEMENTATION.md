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
