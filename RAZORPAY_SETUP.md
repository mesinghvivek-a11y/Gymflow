# Razorpay setup — gym collections

Each gym connects its own Razorpay merchant account. Member fees are collected directly in that gym's Razorpay account; this does not use GymFlow's separate platform billing account.

## 1. Prerequisites

- Apply migrations `0001_core.sql`, `0002_memberships_and_collections.sql` and `0003_razorpay_gateway.sql`.
- Configure `SUPABASE_SERVICE_ROLE_KEY` and `GYMFLOW_ENCRYPTION_KEY` on the server.
- Deploy the app over HTTPS and set `NEXT_PUBLIC_APP_URL`.

## 2. Connect a gym

Sign in as that gym's owner/manager and open **Settings → Online payments · Razorpay**. Enter a matching Key ID, Key Secret and webhook secret from the same Razorpay Test or Live account. GymFlow authenticates the API key by making a small read-only request, encrypts the secrets with AES-256-GCM and stores them server-side. The webhook secret is verified when Razorpay sends its first signed event.

## 3. Configure webhook

Copy the exact webhook endpoint displayed on Settings. In the gym's Razorpay Dashboard, add that URL and subscribe to:

- `payment_link.paid`

Use the webhook secret you saved in GymFlow. The receiver validates `X-Razorpay-Signature` using the unchanged raw request body, then stores the event. It does not trust client-side redirects.

## 4. Worker schedule

The app exposes `/api/internal/workers/razorpay`. `vercel.json` calls it once per minute. Configure Vercel `CRON_SECRET` or `GYMFLOW_WORKER_SECRET`; the worker requires `Authorization: Bearer <secret>`.

For local/manual checks:

```sh
curl -H "Authorization: Bearer $GYMFLOW_WORKER_SECRET" \
  "$NEXT_PUBLIC_APP_URL/api/internal/workers/razorpay"
```

## 5. Verification flow

1. Gym staff creates a membership, which creates an invoice using the plan's stored price snapshot.
2. Staff requests a payment link. The DB reserves the current unpaid invoice balance and reference ID under a request key.
3. The worker fetches the Payment Link and linked Payments from Razorpay.
4. Only a matching captured Payment in INR is allocated to the invoice by the service-role-only database RPC.
5. The invoice and membership state change atomically; duplicate events/payment IDs do not create a second receipt.

## 6. Test Mode checklist

- Verify payment-link amount equals the exact outstanding balance.
- Replay a `payment_link.paid` webhook and confirm one payment and one allocation.
- Send a bad signature and confirm rejection.
- Create a payment link, record an offline partial payment, then pay the old link; the mismatch must be flagged for review, not over-allocated.
- Test webhook replay and worker retry/dead-letter behaviour.

Do not switch a real gym to Live Mode until settlements, refunds, website/app review, policies and support operations have been tested.
