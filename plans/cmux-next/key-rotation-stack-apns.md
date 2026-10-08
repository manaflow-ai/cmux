# Zero-downtime rotation: Stack server key and APNs key

Bead cx-44j.22. Decisions PROD-ROTATION and "Key rotation" (2026-10-04): the new key is valid next to the old one, every consumer moves, a real check passes, then Lawrence approves each revoke. Never print, log or paste a key; pass values through `~/.secrets/*` files or stdin only.

## 1. Why no code change gives the overlap

Both keys are outgoing credentials. Our code presents one key; the provider (Stack, Apple) checks it. The overlap window is provider-side: Stack keeps every unrevoked key set valid, and Apple keeps every unrevoked APNs auth key valid for the whole team. Each consumer switches atomically on its next deploy (a Vercel deployment, a Worker version), and the old deployment keeps serving with the old key until then, so no request runs without a valid key. A second "previous key" fallback in code was considered and rejected: it adds a second secret per consumer and a code path that only runs in a fault, while the swap is already atomic and the rollback (section 5) is one revert.

The one real blocker is client-side: shipped apps send the production Stack publishable key `pck_kzj80…` (public value, from the "prod" key set). Stack accepts requests without a key but rejects a revoked one (401 `INVALID_PUBLISHABLE_CLIENT_KEY`), so revoking the set that holds it signs every installed app out. feat-cmux-next stopped sending it (`1b18c86e8f95`); **cmux `main` still ships it** in `Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthConfig.swift` (stable macOS and iOS), and `main` web still requires `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`. See section 3 step S7.

## 2. Consumers (names only; never values)

Stack production project `9790718f-14cd-4f7e-824d-eaf527a82b82`, server key:

| consumer | variable | how it changes |
| --- | --- | --- |
| Vercel `cmux` web, Production (cmux.com, from `main`) | `STACK_SECRET_SERVER_KEY` (Sensitive), `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY` | Vercel env + redeploy |
| Cloudflare Worker `cmux-api` (cloud-api.cmux.dev, from feat-cmux-next `backend/`) | secret `STACK_SECRET_SERVER_KEY` | `~/.secrets/cmux-next-api-production.env` + `backend/scripts/deploy-worker.sh production` (or the gated CI job) |
| GitHub `manaflow-ai/cmux` repo secret | `STACK_SECRET_SERVER_KEY` (`iroh-release-gate.yml`, `cloud-vm-*.yml` without environment) | `gh secret set … < file` |
| GitHub environments `cloud-vm-production`, `cloud-vm-canary` | `STACK_SECRET_SERVER_KEY` | `gh secret set --env …` |
| local operator files | `~/.secrets/cmux*.env` that hold the production key | edit in place |

Check each GitHub secret's project before touching it (staging, `cmux-vm-*` and `ios-e2e` secrets normally hold the development project's keys and stay as they are). A secret's value cannot be read back; the owner of each workflow knows which project it targets, and a failing smoke after the swap shows a wrong guess.

APNs auth key (team-wide; one `.p8` signs pushes for every app of the team):

| consumer | variables | how it changes |
| --- | --- | --- |
| Vercel `cmux` web, Production (`/api/notifications/push`, stable macOS -> iOS) | `CMUX_APNS_KEY_P8`, `CMUX_APNS_KEY_ID`, `CMUX_APNS_TEAM_ID` | Vercel env + redeploy |
| Cloudflare Worker `cmux-api` (Home / feed pushes) | `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | secrets file + deploy-worker.sh |
| chatmux backend Worker (manaflow-ai/chatmux, `apps/backend`, W50 pushes for `dev.cmux.chatmux`) | `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | wrangler secret + deploy (chatmux deploy rules) |

Revoking an APNs key stops every consumer that still uses that key id, in every repo. Compare key ids (not secret) across all three consumers first.

## 3. Stack server key

S0 (read-only, Lawrence or an agent with dashboard access): in the Stack dashboard for the production project, list the key sets with their descriptions and creation dates. Record which set holds the current server key and which holds the shipped publishable key `pck_kzj80…`. If they are one set (expected: the exposed "prod" set), the revoke in S6 waits for S7.

S1 (needs Lawrence: create): create a new key set with a secret server key and a publishable client key (web needs one while `main` web still requires it). Store both values only in `~/.secrets/stack-prod-<date>.env` (mode 0600).

S2: update the consumers in this order, each from the secrets file through stdin, never argv:
1. Vercel Production `STACK_SECRET_SERVER_KEY` and `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY` (type Sensitive for the server key). Redeploy the current production deployment (`vercel redeploy` of the live deployment, not a new build from a branch).
2. `cmux-api` Worker: update `~/.secrets/cmux-next-api-production.env`, run the production deploy (gated).
3. GitHub secrets that hold the production key (section 2).
4. Local operator files.

S3 verify, after each consumer:
- web: sign in at cmux.com in a fresh browser profile; open the dashboard; a server route that calls Stack (for example the account page) answers 200. Axiom: no rise of 5xx with `stack` in the error on `cmux.com` for 15 minutes.
- `cmux-api`: `GET https://cloud-api.cmux.dev/health` 200, then one authenticated request from the Mac app (open Cloud) that makes the Worker call Stack.
- GitHub: dispatch `cloud-vm-smoke.yml` (production) once; it must pass.

S4: wait 24 hours with both sets valid; watch Axiom and Sentry for Stack auth errors.

S5 rollback (any time before S6): put the old values back from the previous secrets file and redeploy; the old set is still valid.

S6 (needs Lawrence: approve revoke): revoke the OLD server key's set only when S3 passed for every consumer, S4 is clean, and, if the set also holds `pck_kzj80…`, S7 is complete. After revoke repeat S3.

S7 (prerequisite for revoking the "prod" set): `main` stops sending the publishable key, as feat-cmux-next did in `1b18c86e8f95` (empty production key in `AuthConfig.swift`, the SDK omits the header, web makes `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY` optional), then stable macOS and iOS ship it and old builds age out (bead cx-44j.21 measures adoption; it is blocked until `main` has the change).

## 4. APNs key

A0 (read-only): compare `CMUX_APNS_KEY_ID` (Vercel), `APNS_KEY_ID` (`cmux-api`) and the chatmux backend's `APNS_KEY_ID`. In the Apple Developer account (Certificates, Identifiers & Profiles > Keys), confirm the team has a free key slot (Apple limits APNs keys per team).

A1 (needs Lawrence: create): create a new key with Apple Push Notifications service enabled; download the `.p8` once into `~/.secrets/apns-<keyid>.p8` (mode 0600); record the key id.

A2: update each consumer that used the old key id, one at a time: Vercel Production (`CMUX_APNS_KEY_P8` with literal `\n` escapes is accepted, `CMUX_APNS_KEY_ID`) + redeploy; `cmux-api` secrets + deploy; chatmux backend secrets + deploy.

A3 verify each consumer with a real push to a test device (Lawrence's iPhone `E4058DA9-F4C7-52DD-951D-0354061B8E89`, signed in to the same account as the Mac):
- Vercel path: on a Mac running stable cmux with phone notifications on, run `cmux notify --title "apns-rotation" --body "<nonce>"` in a terminal; the notification with that nonce arrives on the iPhone. A `403 InvalidProviderToken` or `ExpiredProviderToken` in Axiom (`cmux.apns.*` span attributes on `/api/notifications/push`) means the key or key id is wrong: roll back (A5).
- `cmux-api` path: trigger a Home feed push to the same iPhone (Home message from another device of the account) and confirm arrival.
- chatmux path: per chatmux's docs, a thread notification to the chatmux iOS app.

A4: keep the old key valid 24 hours; watch for APNs 403s.

A5 rollback: restore the old `.p8` and key id and redeploy; the old key is valid until A6.

A6 (needs Lawrence: approve revoke): revoke the old key in the Apple Developer account only after A3 passed on every consumer that used it. After revoke, repeat A3 once.

## 5. Rollback summary

Until a revoke, every step is reversible by restoring the previous values and redeploying. After a revoke there is no rollback: create a new key and repeat the rollout. That is why each revoke needs Lawrence's explicit approval after the checks.
