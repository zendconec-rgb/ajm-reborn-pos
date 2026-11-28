#!/usr/bin/env node
// Static regression checks for AJM Reborn POS device management.
// Run: node scripts/verify-device-management.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const sql = readFileSync(new URL('../supabase/migrations/20261128_device_management.sql', import.meta.url), 'utf8');
const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');

const mustContain = (source, pattern, message) => assert.match(source, pattern, message);
const mustNotContain = (source, pattern, message) => assert.doesNotMatch(source, pattern, message);

// SQL schema and access controls
mustContain(sql, /create table if not exists public\.ajm_pos_devices/i, 'device registry table missing');
mustContain(sql, /enable row level security/i, 'RLS is not enabled');
mustContain(sql, /revoke all on public\.ajm_pos_devices from anon, authenticated/i, 'direct table access must remain revoked');
mustContain(sql, /auth\.jwt\(\)->'app_metadata'/i, 'admin authorization must use trusted app_metadata');
mustContain(sql, /AJM_DEVICE_ADMIN_REQUIRED/g, 'server-side admin guard missing');
mustContain(sql, /pg_advisory_xact_lock/g, 'concurrency lock missing');
mustContain(sql, /if not v_exists and v_count >= 3 then/i, 'new device limit must be exactly three');
mustContain(sql, /if v_count >= 3 then/i, 'restore operation must enforce three-device cap');
mustContain(sql, /revoke all on function public\.ajm_pos_register_device\(uuid,text,text\) from public, anon/i, 'registration RPC must not be executable by anon/public');
mustContain(sql, /grant execute on function public\.ajm_pos_register_device\(uuid,text,text\) to authenticated/i, 'authenticated registration grant missing');
mustNotContain(sql, /end; \$;/, 'malformed SQL function terminator detected');
mustNotContain(sql, /as \$(?:\r?\n)/, 'malformed SQL dollar quote detected');

// Browser integration
mustContain(html, /ajm_pos_register_device/, 'registration RPC not called by app');
mustContain(html, /ajm_pos_list_devices/, 'device list RPC not called by app');
mustContain(html, /ajm_pos_revoke_device/, 'revoke RPC not called by app');
mustContain(html, /ajm_pos_restore_device/, 'restore RPC not called by app');
mustContain(html, /AJM_DEVICE_REVOKED/, 'revoked-device response is not handled');
mustContain(html, /setInterval\(sendAjmDeviceHeartbeat,\s*60000\)/, '60-second heartbeat missing');
mustContain(html, /card-device-management/, 'device management settings panel missing');

// Parse every inline script without executing browser code.
const inlineScripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
  .map(match => match[1]).filter(source => source.trim());
inlineScripts.forEach((source, index) => new vm.Script(source, { filename: `inline-script-${index + 1}.js` }));

console.log('PASS: device migration static checks');
console.log(`PASS: ${inlineScripts.length} inline JavaScript blocks parse successfully`);
console.log('NOTE: live database/Auth tests still require an isolated Supabase test database.');
