# GymFlow platform subscriptions and licences

This is GymFlow's own software billing, not the gym's fees collected from members. The platform uses a separate Razorpay account and separate database tables.

## Separation rules

- Gym payment integration: per-gym Razorpay credentials, `payments`, `invoices`, `payment_allocations` and gym reports.
- GymFlow SaaS billing: platform-level Razorpay credentials, `platform_products`, `platform_subscriptions`, `platform_licences`, `platform_payments`, `platform_payment_links` and `platform_webhook_events`.
- A gym collection must never increment platform revenue, MRR or licence activation.
- A platform payment must never pay a gym member's invoice.

## Seed catalogue

Migration `0005_platform_billing_and_entitlements.sql` seeds three hypotheses:

| Product | Price | Billing |
|---|---:|---|
| Starter | ₹699 | Monthly subscription |
| Growth | ₹1,299 | Monthly subscription |
| Perpetual Core Licence | ₹14,999 | One-time licence |

These are not market-validated prices. Adjust them before accepting real customers. The one-time licence scope grants only the listed core feature entitlements/defined version; it is not a promise of unlimited hosting, support, messaging or lifetime feature upgrades.

## Checkout

1. A gym owner opens **GymFlow billing** and selects a plan/licence.
2. A server RPC creates a platform payment request under an idempotency key.
3. GymFlow creates a Payment Link using `PLATFORM_RAZORPAY_KEY_ID` and `PLATFORM_RAZORPAY_KEY_SECRET` (a dedicated platform merchant account).
4. The platform webhook at `/api/platform/razorpay/webhook` verifies the signature, fetches the payment link and captured payment from Razorpay, and then calls the service-role-only `apply_verified_platform_payment` RPC.
5. The database transaction marks the platform payment successful and activates a subscription term or perpetual licence.

Set these server-only variables separately from per-gym credentials:

- `PLATFORM_RAZORPAY_KEY_ID`
- `PLATFORM_RAZORPAY_KEY_SECRET`
- `PLATFORM_RAZORPAY_WEBHOOK_SECRET`

Configure the platform Razorpay webhook to `https://YOUR_GYMFLOW_DOMAIN/api/platform/razorpay/webhook` and subscribe to `payment_link.paid`.

## Entitlements and admin

`gymflow_entitlements(gym_id)` resolves the active licence/subscription on the server. Current policy: an active perpetual licence takes precedence over any recurring subscription and its entitlement snapshot becomes the access scope. Otherwise an active/trialing subscription grants full access; an eligible `past_due`/`grace_period` record grants grace access; expired/no billing gives read-only access. Database triggers currently enforce member caps, staff caps, WhatsApp entitlement and online payment entitlement. Full access gating for every other write action, plus expiry/grace UI and dunning, remains required before production. Do not rely on hidden buttons as the paywall.

The `/platform` console is restricted by the `platform_admins` table. Bootstrap a trusted platform admin by inserting the authenticated user's UUID in Supabase SQL Editor:

```sql
insert into public.platform_admins(user_id)
values ('YOUR_AUTH_USER_UUID')
on conflict do nothing;
```

The console shows registered gyms, active subscriptions, active licences, MRR, platform receipts and failed/review payments. MRR is an operational estimate from active subscription products, not audited accounting revenue.

## Remaining commercial work before launch

- Complete server-side entitlement enforcement for every write action and all remaining paid features (member/staff quota and WhatsApp/online-payment feature gates have initial DB enforcement).
- Subscription cancellation, grace-period UI/policy, dunning and recurring auto-charge strategy.
- Refunds, credit notes, tax/GST invoice and formal accounting treatment.
- Customer-facing legal licence terms, data export/retention and support policy.
- Platform admin product CRUD, pricing change audit, tenant support/impersonation safeguards and reconciliation.
- Live Razorpay test account verification, settlement/refund testing and monitoring.
