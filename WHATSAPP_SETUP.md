# WhatsApp Business Cloud API setup

GymFlow uses the official WhatsApp Business Platform. No WhatsApp Web automation or unofficial browser scripts are used. Each gym stores its own connection and token.

## 1. Prerequisites

Apply all migrations through `0004_whatsapp_reminders.sql`. Configure these server variables:

- `GYMFLOW_ENCRYPTION_KEY`
- `WHATSAPP_APP_SECRET` — Meta App Secret used to verify `X-Hub-Signature-256`
- `WHATSAPP_WEBHOOK_VERIFY_TOKEN` — a random string you choose and also enter in Meta App Dashboard
- `GYMFLOW_WORKER_SECRET` or Vercel `CRON_SECRET`
- `NEXT_PUBLIC_APP_URL`

## 2. Connect a gym

As the gym owner/manager open **Settings → WhatsApp reminders** and enter its WABA ID, Phone Number ID, System User access token, Graph API version and approved reminder template names. GymFlow validates that the phone-number ID is part of the supplied WhatsApp Business Account, then encrypts the access token at rest.

The Graph API version is stored per gym. Keep it current according to Meta's version support schedule; GymFlow does not hard-code a version that may later be retired.

## 3. Approved templates

Create and obtain approval for two utility templates in WhatsApp Manager. Each template must contain three body parameters in this order:

1. Member name
2. Gym name
3. Expiry date

Example *draft wording only* (not pre-approved):

- Pre-expiry: `Hi {{1}}, your membership at {{2}} expires on {{3}}. Please contact the gym to renew.`
- Due today: `Hi {{1}}, your membership at {{2}} expires today ({{3}}). Please contact the gym if you wish to renew.`

Use the exact approved template names and approved language code in Settings. Business-initiated reminders may incur Meta charges; charges are not unlimited or included in the base GymFlow licence.

## 4. Configure Meta webhook

Callback URL:

`https://YOUR_GYMFLOW_DOMAIN/api/whatsapp/webhook`

Configure the callback verification token to match `WHATSAPP_WEBHOOK_VERIFY_TOKEN`, subscribe to the `messages` field, and set `WHATSAPP_APP_SECRET` on the server. The webhook checks the HMAC signature over the raw request body, maps the incoming phone-number ID to a gym and stores delivery events durably.

Inbound STOP, UNSUBSCRIBE, CANCEL, END and QUIT messages revoke consent and cancel pending reminders. Unrelated inbound message bodies are not retained.

## 5. Reminder rules

- First reminder: 3 calendar days before the membership's gym-local expiry date.
- Second reminder: on the expiry date.
- Default send time: 10:00 in the gym timezone; owners/managers can change it in Settings.
- Only paid or waived memberships are scheduled; only members with recorded opt-in are eligible.
- Renewal, pause, cancellation, opt-out or a changed membership cycle prevents stale reminders from being sent.

The worker runs once per minute at `/api/internal/workers/whatsapp`. `vercel.json` includes the schedule. Delivery callbacks progress through accepted/sent/delivered/read/failed. An uncertain send is `unknown` and is not automatically retried because Meta may have accepted the message even if the client timed out.

## 6. Consent and safe testing

- Obtain express consent before enabling reminders; capture how the member agreed.
- Keep the consent source record and respect opt-outs.
- Test only with an approved test WABA and consenting numbers.
- Verify the schedule in more than one timezone, including a daylight-saving timezone if selling internationally.
- Revoke a test token and confirm the connection is flagged for attention.
- Test inbound opt-out, delivery callbacks, duplicate callbacks and worker interruption.

The gym is responsible for its own privacy notices, lawful basis/consent, opt-outs, and compliance with applicable law and Meta's current Business Messaging Policy.

Official references:
- https://whatsappbusiness.com/developers/developer-hub/
- https://business.whatsapp.com/policy
- https://developers.facebook.com/docs/graph-api/
