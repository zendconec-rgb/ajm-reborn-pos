import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html = fs.readFileSync('index.html', 'utf8');
const client = fs.readFileSync('assets/js/ajm-multidevice-client.js', 'utf8');
const saleSql = fs.readFileSync('supabase/migrations/20261128_002_atomic_sale_processor.sql', 'utf8');
const debtSql = fs.readFileSync('supabase/migrations/20261128_006_atomic_debt_payment.sql', 'utf8');
const workOrderSql = fs.readFileSync('supabase/migrations/20261128_007_atomic_work_order_completion.sql', 'utf8');

let inlineScripts = 0;
for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
  if (/\bsrc\s*=/.test(match[1]) || !match[2].trim()) continue;
  new vm.Script(match[2], { filename: `index-inline-${++inlineScripts}.js` });
}
assert.ok(inlineScripts > 0, 'No inline application scripts were validated');
new vm.Script(client, { filename: 'ajm-multidevice-client.js' });

assert.ok(!html.includes('ajm_reborn_empty_products_transactions_20261128_v1'),
  'Destructive startup migration marker must not return');
assert.ok(html.includes('requiredStock = new Map()'),
  'Checkout must aggregate product quantities before stock validation');
assert.ok(html.includes('workOrderId: activeWorkOrderId ? String(activeWorkOrderId) : null'),
  'Checkout must preserve the linked work-order ID');
assert.ok(!html.includes('Math.max(0, Number(pr.stock || 0) - Number(ci.qty || 0))'),
  'Checkout must not silently clamp insufficient stock to zero');

assert.equal((saleSql.match(/create or replace function public\.ajm_process_sale/g) || []).length, 1,
  'Sale RPC must have one definition');
assert.equal((saleSql.match(/\bcommit;/gi) || []).length, 1,
  'Sale migration must have one transaction commit');
for (const token of ['stock_conflict', 'duplicate_invoice', 'operation_id_conflict',
  'workOrderId', 'work_order_conflict', 'completedInvoice']) {
  assert.ok(saleSql.includes(token), `Sale RPC missing required invariant: ${token}`);
}
for (const [name, source, tokens] of [
  ['debt payment', debtSql, ['ajm_apply_debt_payment', 'amount_exceeds_debt', 'already_applied']],
  ['work-order completion', workOrderSql, ['ajm_complete_work_order', 'already_completed']]
]) {
  for (const token of tokens) assert.ok(source.includes(token), `${name} migration missing: ${token}`);
}
assert.ok(html.includes('assets/js/ajm-multidevice-client.js'),
  'Multi-device client must be loaded by the application');
assert.ok(html.includes('window.AJM_MULTI_DEVICE.configure({ supabase: ajmSupabase'),
  'Multi-device client must receive the initialized Supabase client');
assert.ok(html.includes('.catch(err => {\n                            window.ajmMultiDeviceModuleReady = false;'),
  'Multi-device initialization failures must be handled without breaking login');
assert.ok(client.includes('async function prepareSession(localUser)'),
  'Client must expose ordered local-identity/device preparation');
assert.ok(client.includes('const identity = await linkLocalIdentity(localUser)'));
assert.ok(client.includes('const device = await registerDevice()'));
assert.ok(client.includes("item.operation_type === 'sale.create'"));
assert.ok(client.includes("item.operation_type === 'debt.payment'"));
assert.ok(client.includes("item.operation_type === 'workorder.complete'"));
assert.ok(client.includes("'work_order_conflict','work_order_not_found'"));

console.log(`AJM validation passed: ${inlineScripts} inline scripts, multi-device client, and staged SQL contract checks.`);
