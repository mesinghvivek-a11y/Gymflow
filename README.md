# GymFlow — Gym Membership & Operations SaaS

**Version:** 0.5.0 foundation build  
**Initial market:** India  
**Primary currency:** INR (all stored amounts are integer paise)

GymFlow is a mobile-first gym operations web app with a PWA manifest foundation. This repository contains the application source, PostgreSQL/Supabase migrations, integration routes and test suite. Service worker/offline support and push notifications are not yet complete. It has **not been connected to a live Supabase, Razorpay or Meta account** and is not certified for production financial operation.

## Stack

- Next.js 16.4.3 App Router, React 19.3.1, TypeScript
- Tailwind CSS 4 with a responsive design system in `src/app/globals.css`
- Supabase Auth, PostgreSQL, Row Level Security and Storage-ready schema
- Razorpay Payment Links, per-gym merchant credentials, signed webhooks and a protected worker
- Official WhatsApp Business Cloud API, per-gym account credentials, consent tracking and reminder worker
- Vercel Cron-compatible worker endpoints

These are stable package versions, not canary builds. Check the current release notes before upgrading: Next.js 16.4.3 was released on 23 October 2026; React 19.3.1 and Supabase JS 2.118.0 are the stable package versions pinned by this build. [Next.js release history](https://github.com/vercel/next.js/releases/) · [React releases](https://github.com/facebook/react/releases) · [Supabase JS releases](https://github.com/supabase/supabase-js/releases)

## Implemented in this build

### Gym operations
- Email/password registration, sign-in, PKCE auth callback and server-verified session claims.
- First-gym onboarding with a server-side database RPC that creates the gym, owner membership and counters atomically.
- Mobile-first dashboard, member directory, plan catalogue, membership assignment/history, dues, payments, reports, message centre and integration settings.
- Five-digit member IDs allocated in a per-gym database counter, protected by a row lock and uniqueness constraint. IDs are never recycled.
- Membership plan snapshots, month-based and day-based durations, advance renewal from the existing expiry instant, and selectable start date for a new/expired term.
- Invoice creation, manual cash/offline-UPI/bank payments, partial allocations and invoice balance controls in database transactions.
- Idempotency keys on member creation, membership assignment, manual payment and payment-link requests.

### Gym payment integration
- Each gym connects its own Razorpay account; credentials are encrypted at rest with AES-256-GCM.
- Payment-link amount and invoice reference are reserved on the server from the current invoice balance.
- Signed webhook receiver stores events durably; a protected worker verifies the Razorpay Payment Link and captured Payment before allocating the receipt.
- Duplicate webhook events and duplicate provider payment references are guarded by database uniqueness and idempotent application.
- A member browser redirect is never treated as proof of payment.

### WhatsApp integration
- Each gym connects its own WhatsApp Business Cloud API account; access token is encrypted at rest.
- Two reminders are scheduled from paid/waived membership terms: three calendar days before expiry and on expiry day, at a configurable gym-local time (default 10:00).
- Member opt-in is required and recorded with a source. Existing members default to opted out.
- Meta webhook HMAC is checked over raw request bytes. Delivery statuses are tracked separately; “accepted” is not shown as “delivered”.
- STOP, UNSUBSCRIBE, CANCEL, END and QUIT revoke consent and cancel pending reminders.
- An ambiguous send is recorded as `unknown` and is not automatically resent, avoiding duplicate member messages.

### GymFlow platform billing (separate from gym collections)
- Separate product catalogue, subscriptions, perpetual licences, platform payments, payment-link records and platform webhooks.
- Dedicated platform Razorpay credentials are separate from every gym’s Razorpay account.
- Verified platform payment grants subscription time or activates a perpetual licence; a one-time licence uses a documented entitlement snapshot.
- Server-side entitlement resolver and restricted `/platform` administration dashboard with gym count, subscriptions, licences, MRR, platform payments and failed billing metrics.
- Seed prices are **commercial test hypotheses**, not validated market prices: Starter ₹699/month, Growth ₹1,299/month and a core perpetual licence ₹14,999. Change the seed data before offering plans to customers.
- The seeded one-time licence does not include unlimited cloud hosting, WhatsApp charges, support or future feature development. Those items must have separately disclosed terms.

## Repository layout

```text
GymFlow/
  src/app/                 Next.js pages, API routes, PWA manifest
  src/components/          Workspace navigation and brand components
  src/domain/              Pure money, membership, phone and timezone rules
  src/lib/                 Supabase clients, workspace auth, secret vault
  src/server/actions/      Validated server actions
  src/server/integrations/ Razorpay and WhatsApp clients/workers
  supabase/migrations/     Ordered PostgreSQL schema and RPC migrations
  tests/                   Node test suite
  README.md
  RAZORPAY_SETUP.md
  WHATSAPP_SETUP.md
  PLATFORM_BILLING.md
  BUILD_STATUS.md
  .env.example
```

## Local setup

Requires Node.js 22 or newer and npm.

1. Create a new Supabase project. Do not use a database that already contains another live GymFlow installation unless you first prepare a reviewed forward migration.
2. Copy `.env.example` to `.env.local`.
3. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` and `NEXT_PUBLIC_APP_URL`.
4. In Supabase SQL Editor, apply the five migrations in numeric order, once, to the fresh project:

   ```text
   0001_core.sql
   0002_memberships_and_collections.sql
   0003_razorpay_gateway.sql
   0004_whatsapp_reminders.sql
   0005_platform_billing_and_entitlements.sql
   ```

5. In Supabase Auth → URL Configuration, set the local Site URL to `http://localhost:3000` and add `http://localhost:3000/auth/callback` to allowed redirect URLs. Add production URLs when deploying.
6. Install and run:

   ```sh
   npm install
   npm test
   npm run typecheck
   npm run dev
   ```

7. Open `http://localhost:3000`. If Supabase variables are missing, GymFlow shows `/setup` rather than fabricated workspace data.

## Server secrets

Generate the encryption key and worker secret locally:

```sh
openssl rand -hex 32
openssl rand -hex 32
```

Set one as `GYMFLOW_ENCRYPTION_KEY` (exactly 32 bytes / 64 hex characters) and the other as `GYMFLOW_WORKER_SECRET` / Vercel `CRON_SECRET`. Back up the encryption key securely. **Changing it without decrypting and re-encrypting every stored provider credential permanently makes existing credentials unreadable.**

Keep `SUPABASE_SERVICE_ROLE_KEY`, Razorpay secrets, Meta App Secret, worker secrets and encrypted provider credentials on the server only. Never put them in `NEXT_PUBLIC_*` variables or commit them.

## Integration setup documents

- [Razorpay per-gym gateway setup](./RAZORPAY_SETUP.md)
- [WhatsApp Business Cloud API setup](./WHATSAPP_SETUP.md)
- [GymFlow subscription and licence billing](./PLATFORM_BILLING.md)

## Security and accounting rules

- Gym data is tenant-scoped by `gym_id`, RLS and composite foreign keys. Do not remove these controls to make a UI query work.
- Service-role credentials bypass RLS and are only used in server-only modules.
- Financial records are append-oriented and audited; never silently delete or overwrite payment history.
- Gym customer collections and GymFlow SaaS billing are separate ledgers and provider credentials.
- Expected future renewals and outstanding dues are not cash collections. Net collections subtract successful refunds.
- Memberships use an exclusive expiry instant: `starts_at <= now < ends_at`. Calendar-month arithmetic is not implemented as a fixed 30-day duration.
- Five-digit IDs are unique within a gym, not globally. The namespace is finite; exhaustion must be handled by a migration, never by recycling IDs.

## Verification status

Run `npm test` for the local regression suite. The suite uses Node's built-in test runner and provider mocks; it does not call live gateways. `BUILD_STATUS.md` records exactly what was checked and what still needs Supabase integration tests, SQL execution, dependency-backed typechecking, browser tests and real-provider staging validation.

**Do not deploy this as a production financial system until the remaining checks in `BUILD_STATUS.md` pass.**
