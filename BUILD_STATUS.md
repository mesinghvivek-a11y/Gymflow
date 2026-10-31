# GymFlow build status — 31 October 2026

## Delivered in this code package (v0.6.0)

### Application foundation
- Next.js 16 App Router, React, TypeScript and Tailwind CSS 4 application structure.
- Email/password registration and login, PKCE callback, server-side auth claim checks, first-gym onboarding and authenticated multi-tenant workspace shell.
- Mobile-first dashboard, searchable member directory, membership plans, membership assignment/history, dues, payments, reports, message centre, settings and GymFlow billing pages.
- Member profile edit and soft archive/restore, with tenant-scoped security-definer RPCs and audit entries (migration `0006_member_management.sql`).
- Web app manifest and icon. A production service worker, push subscription UI and full offline strategy remain to be added.

### Gym membership and collections
- Five-digit member IDs allocated from a per-gym database counter with a uniqueness constraint, row-level locking and idempotency keys. IDs are not recycled.
- Plan snapshots and month/day durations; month-end arithmetic uses calendar months; advance renewal preserves unused days.
- Invoice generation, manual cash/UPI/bank receipts, partial allocations and invoice balance enforcement through database transactions.
- Finance reporting distinguishes gross collections, refunds, net collections and unpaid balances.

### Payment and messaging integrations
- Per-gym Razorpay connection, encrypted credentials, invoice-reserved payment links, signed raw-body webhook verification and a protected worker that confirms provider-side capture before allocating payment.
- Official WhatsApp Cloud API connection per gym; encrypted access token; approved-template send worker; member consent and audit trail; STOP/UNSUBSCRIBE/CANCEL/END/QUIT opt-out handling.
- Reminder rules: three calendar days before expiry and on expiry date, at configurable gym-local time. Old-term reminders are suppressed after an advance renewal.
- Delivery states distinguish provider acceptance from sent/delivered/read/failed. Uncertain sends are marked `unknown` and not automatically repeated.

### GymFlow platform billing
- Separate product, subscription, licence, platform payment and webhook ledgers with separate Razorpay credentials.
- 14-day Starter trial on newly created gyms; a seed migration backfills a trial for existing gyms without subscription/licence.
- Server-side entitlement resolver, limited DB feature/quota triggers, platform payment verification and protected platform admin metrics.
- Seed prices are illustrative hypotheses only. Product CRUD, recurring auto-charge/dunning, refunds/GST invoices, legal licence terms and full entitlement gating of every write action remain pending.

## Verification performed in this workspace

- `npm test` — **30 passed, 0 failed** using Node's built-in test runner.
- `node --check` — all executable JavaScript modules passed.
- TypeScript/TSX syntax transpilation — **47 files parsed, 0 syntax diagnostics** using the globally installed TypeScript compiler.
- Full dependency-backed `tsc --noEmit` and `next build` were not run: dependencies are not installed in this workspace. An earlier dependency installation attempt timed out while reaching the npm registry.
- PostgreSQL migrations were not executed against a live Supabase database and have not received a live integration test. Static SQL contract tests are not a substitute for running migrations in staging.
- Razorpay and Meta API tests use local provider mocks; no real merchant accounts or approved WhatsApp templates were connected.

## Required before production

1. Install dependencies, generate/commit a lockfile, run `npm run typecheck` and `npm run build`.
2. Apply all migrations in order to a fresh Supabase staging project; fix any PostgreSQL errors and run adversarial tenant/RLS tests with two separate gyms and users.
3. Test auth emails, password reset, onboarding, membership creation, manual/partial payments, refunds, reporting and concurrent idempotency against PostgreSQL.
4. Verify Razorpay Test Mode links, webhook replay, duplicate payments, amount mismatch, refunds and settlement reconciliation.
5. Verify Meta test WABA, approved templates, opt-in/out, callback order, worker crash recovery and delivery costs.
6. Complete full entitlements on every paid write action; test subscription expiry, grace periods, one-time licence precedence and staff/member caps.
7. Implement service worker/offline behavior and optional web push; test iOS Safari and Android Chrome.
8. Perform backup/restore, monitoring, privacy/retention, incident response, customer support and production deployment drills.

Additional performance work: these changes reduce avoidable request round trips and improve perceived navigation feedback. They have not been benchmarked against the live Vercel/Supabase deployment; confirm using browser DevTools and real-device tests.

Still pending: refunds/credit notes/GST invoices, complete subscription lifecycle/dunning and entitlement enforcement, plan/product administration, secure data export, production scheduler setup and full offline/PWA push support.

**Status: development build delivered; not production-ready.** No live service has been configured or deployed from this package.
