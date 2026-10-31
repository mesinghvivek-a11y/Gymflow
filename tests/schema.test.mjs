import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
const dir=new URL('../supabase/migrations/',import.meta.url);const migrations=readdirSync(dir).filter(f=>f.endsWith('.sql')).sort().map(f=>readFileSync(new URL(f,dir),'utf8'));
const all=migrations.join('\n');
test('all tenant tables carry gym ownership, RLS and tenant-safe foreign keys',()=>{for(const t of ['members','membership_plans','memberships','invoices','payments','payment_allocations','gateway_connections','reminder_jobs','whatsapp_messages']){assert.match(all,new RegExp(`create table public\\.${t}\\s*\\(`, 'i'),`missing ${t}`);}assert.match(all,/alter table public\.memberships[^;]*enable row level security|foreach t in array/i);assert.match(all,/foreign key\(gym_id,member_id\) references public\.members\(gym_id,id\)/i);});
test('money is integer paise and financial writes are server-only',()=>{assert.match(all,/amount_paise bigint not null/);assert.match(all,/revoke insert,update,delete on public\.invoices,public\.invoice_items,public\.payments/);});
test('member IDs are allocated through a gym-local counter and idempotency key',()=>{assert.match(all,/gym_member_counters/);assert.match(all,/member_id_space_exhausted/);assert.match(all,/unique\(gym_id,request_key\)/i);});
test('advance renewal and manual payment transaction functions exist',()=>{assert.match(all,/create_membership_for_gym/);assert.match(all,/latest_end/);assert.match(all,/record_manual_payment_for_gym/);assert.match(all,/payment_exceeds_balance/);});
test('Razorpay webhook events are deduplicated and capture verified server-side',()=>{assert.match(all,/unique\(provider,provider_account_id,event_id\)/i);assert.match(all,/claim_razorpay_webhook_events/);assert.match(all,/record_verified_razorpay_payment/);});
test('WhatsApp reminders schedule -3 days and expiry date with opt-out',()=>{assert.match(all,/expiry_date-3/);assert.match(all,/due_today/);assert.match(all,/whatsapp_opt_in/);assert.match(all,/member_opted_out/);assert.match(all,/claim_whatsapp_reminder_jobs/);});
test('GymFlow SaaS billing has isolated ledgers and server-side entitlement resolver',()=>{assert.match(all,/create table public\.platform_payments/);assert.match(all,/create table public\.platform_subscriptions/);assert.match(all,/create table public\.platform_licences/);assert.match(all,/gymflow_entitlements/);assert.match(all,/apply_verified_platform_payment/);assert.match(all,/platform_admin_metrics/);});

test('perpetual licence resolves to full access and paid feature triggers enforce active entitlements',()=>{
  const billing=migrations.join('\n');
  assert.match(billing,/billingSource','perpetual_licence','access','full/);
  assert.match(billing,/feature_not_in_plan:whatsappAutomation/);
  assert.match(billing,/feature_not_in_plan:onlinePayments/);
  assert.match(billing,/new\.status <> 'active'/);
});

test('paid advance renewal cancels and suppresses reminders for the previous term',()=>{
  const reminders=migrations.join('\n');
  assert.match(reminders,/last_error='membership_renewed'/);
  assert.match(reminders,/older\.ends_at=new\.starts_at/);
  assert.match(reminders,/successor\.starts_at=ms\.ends_at/);
});

test('there is one canonical initial schema migration and later migrations are uniquely ordered',()=>{
  const names=readdirSync(dir).filter(f=>f.endsWith('.sql')).sort();
  assert.equal(names.filter(f=>f.startsWith('0001_')).length,1);
  assert.deepEqual(names.map(f=>f.slice(0,4)),['0001','0002','0003','0004','0005']);
});
