# Review account: a working Chief with no Mac

The NEXT iOS app (`ios/`, bundle `com.cmux.app`) signs in and opens Home, where the account's
Hosted Chief is pinned at the top. The Hosted Chief has no `brain_place`: the Cloud Chief brain in
the production API Worker (`backend/apps/api`, `cloud-api.cmux.dev`) answers it, so a reviewer
needs no Mac, no pairing, no tailnet and no Cloud machine. This page is the operator setup that
makes that Chief answer for the review account, and the steps the reviewer follows. Credentials,
account emails, inbox links and keys go only in the store's review information form, never here.

## Why a Hosted Chief and not a demo mode or a review Mac

- Every production signup already gets a Hosted Chief: the signup outbox runs
  `chief.default.ensure` (`backend/apps/api/src/domains/user-chief-default.ts`), which makes the
  Chief and its main conversation, the row Home pins.
- Production runs Cloud Chief brains (`CHIEF_BRAIN_ENABLED=1`, model `claude-opus-5-5`,
  `backend/apps/api/wrangler.jsonc`) but not machines (`HANDS_ENABLED` unset), so signup cannot
  bind a default machine and leaves the brain unconfigured (`activateDefault` answers
  `provisioning_pending`, `src/chief-brain/brain-do.ts`). A brain turned on by its owner
  (`PUT /v1/chiefs/<agent>/brain {"enabled": true}`) then answers with no machine at all.
- Who may run turns on a metered model is server config, not app code: `meteredOwner`
  (`src/model-gateway/routes.ts`) reads `CHIEF_BRAIN_CLAUDE_OWNERS` plus the secret
  `CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA`, which exists for exactly this ("owners that change often,
  such as a demo's test user", `src/chief-brain/claude-auth.ts`). Each turn also needs the payer
  team's prepaid credits (`src/chief-brain/brain-gateway.ts`), granted through the operator route
  `POST /v1/internal/credits` (`src/credits-admin.ts`).
- So the review account is marked on the server only: its personal team on the secret owner list
  and a credits grant. The app has no review switch, no hardcoded account and no canned content;
  the reviewer uses the same Home, Chief and chat every person gets.
- The older demo hook (`demonstrationContentEnabled`, `MobileDemoContentCatalog` in
  `Packages/iOS/CmuxMobileShellModel`) belongs to the classic app's packages. The NEXT app does not
  link that package, nothing turns the hook on, and its "Demo Mac" answers no chat. It is not used.

## What the app does for this path

Home reads the Hosted Chief's brain when it comes online and to the foreground. While the brain is
off, Home shows a "Chief Is Off" card with Turn On (Try Again after a failure), so the Chief is
never silent with no reason given. When the server refuses Turn On because the account may not run
the Chief's model (`chief_claude_unavailable`, an account not on the owner list), the card says
"Chief isn't available on this account." and offers no button. A read never turns a brain on; only
the person's tap does. A self-hosted chat server and a deployment with brains off show nothing.

## Operator setup, once per review account (production)

1. Make the review account in the production sign-in project with an email whose inbox the reviewer
   can open from the review notes (a public disposable inbox), and mark the email verified, so
   sign-in goes straight to the code screen. Use a fictional display name.
2. Sign in once with that account in the NEXT iOS app. This runs signup: Home shows the pinned
   "Chief" row. Do not create other Chiefs or conversations.
3. Grant the account's personal team prepaid credits through the operator credits route on
   `cloud-api.cmux.dev` with the billing operator key: action `grant`, `stack_user` set to the
   account's sign-in user id, a small amount (20 USD covers a review), a unique `key`, your
   `actor`, and a `reason` such as "app review account". The answer names the personal team id
   (`team_...`).
4. Add that `team_...` id to the production API Worker secret `CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA`.
   Setting the secret replaces its whole value: read the current list from whoever owns it and
   write the list with the new id added. No deploy is needed.
5. In the app, on the review account: Home shows "Chief Is Off". Tap Turn On, open Chief, send
   "hello" and wait for the reply. The card does not come back after a relaunch. If the card says
   "Chief isn't available on this account.", step 4 has not taken effect: check the secret.
6. Leave the account signed in nowhere else. Fill the review information form: the email, "no
   password: sign in with the emailed code", the public inbox link, and the reviewer steps below.

## Reviewer steps (paste into the review notes)

1. Open cmux. Enter the demo account email in "Email address" and tap "Email me a code".
2. Open the inbox link from these notes, open the newest cmux email, and enter its code. Tap
   "Verify code".
3. Home opens with Chief pinned at the top. No Mac, pairing or other device is needed.
4. Tap Chief, type a message (for example "What can you help me with?") and send it. Chief answers
   in the conversation within a few seconds.
5. If Home shows "Chief Is Off", tap Turn On, then send the message again.

## Checks before each submission

- The steps above work from a phone that has never signed in to the account, on a network outside
  the office.
- The account's credits read above zero (operator credits route, action `read`).
- The owner list still names the account's team (a replaced secret drops it).

## After review

Remove the team id from `CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA`, archive the account's conversations, and
change the account's inbox or delete the account, because anyone with the public inbox can sign in.
