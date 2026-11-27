# Development Cloud: the `cmux-cloud-dev` GitHub App

The development API Worker (`cmux-api-development`) connects GitHub with its own App,
`cmux-cloud-dev` under manaflow-ai, so Connect GitHub, the git credential helper and
`cmux github gh` can be tested on development Cloud machines without touching the staging or
production Apps. Background: `plans/cmux-next/cloud-github-auth-DESIGN.md`.

## How a development connect comes back

Development has no hosted console (its `DASHBOARD_ORIGIN` is `http://localhost:3010`, which a
browser elsewhere cannot reach). So `env.development` sets
`INTEGRATIONS_CALLBACK_ORIGIN = https://console-staging.cmux.dev`, and every provider redirect
(GitHub's install return and the OAuth authorize path) lands on the staging console's
`/integrations/callback`. Pairing and SSO keep `DASHBOARD_ORIGIN`.

The callback page reads the state's issuer (`https://cmux-api/<environment>`, unverified, a
routing hint only). On the staging console a `development` state finishes on
`https://cmux-api-development.debussy.workers.dev`, which verifies the signature, user and team
as always; every other state finishes on the console's own API. Before it sends the session
on, the console checks that the development API's published key (`/.well-known/jwks.json`)
signed the state, and signed it for the console session's own person. A hand-made link naming
the development issuer, or someone else's genuine link, goes nowhere. The development API gets
one access token, once: the console refreshes its own session first if it has run out.
Development and staging share one sign-in project, so the staging console's session is valid
on the development API. The production console never forwards. Tests pin the URLs to `wrangler.jsonc`
(`backend/apps/dashboard/test-server/integration-callback-route.test.ts`).

A connect the cmux app started never reaches that step: the callback page sends the browser
straight back to the app (`integrationAppHandoff`, the state's `<scheme>://integration/complete`
return link), and the DEV build finishes it on the development API with its own sign-in. The
forwarding above is for a connect started from a chat or from the console, which the page
finishes itself: it ends on "Connected to the development Cloud", or returns to the chat or
GitHub's configure page like any other connect.

## The App

`backend/apps/api/scripts/dev-github-app.ts manifest` prints it:

```json
{
  "name": "cmux-cloud-dev",
  "url": "https://cmux.com",
  "description": "cmux Cloud development: repository access for development Cloud machines and agents, only where you allow.",
  "hook_attributes": {
    "url": "https://cmux-api-development.debussy.workers.dev/v1/hooks/github",
    "active": true
  },
  "redirect_url": "http://127.0.0.1:3011/created",
  "callback_urls": [
    "https://console-staging.cmux.dev/integrations/callback"
  ],
  "request_oauth_on_install": true,
  "setup_on_update": true,
  "public": true,
  "default_permissions": {
    "actions": "read",
    "checks": "read",
    "contents": "write",
    "issues": "write",
    "members": "read",
    "metadata": "read",
    "pull_requests": "write",
    "statuses": "read",
    "workflows": "write"
  },
  "default_events": [
    "check_run",
    "check_suite",
    "issue_comment",
    "issues",
    "pull_request",
    "pull_request_review",
    "pull_request_review_thread",
    "push",
    "status"
  ]
}
```

Compared with `cmux-cloud-staging` (contents read, issues and pull requests write, members and
metadata read; events issues, issue comment, pull request, push), development adds what the code
asks for: contents write (git push), checks, actions and statuses read (`cmux github gh`),
workflows write (minted only when the team policy allows workflows), and the events the live
pull request list uses (`github-push.ts`). The test `test-node/dev-github-app.test.ts` checks
the manifest against the token permissions, the push events and `wrangler.jsonc`.
`request_oauth_on_install` must stay on: completion needs the user's code beside the
installation id. `public` lets test accounts install it outside manaflow-ai.

## Secrets on `cmux-api-development`

GitHub counts as configured when all of these are set (`src/http.ts` integration.connect,
`src/integrations/providers.ts` `github.configured`):

| Name | Source |
|---|---|
| `INTEGRATIONS_KEK` | 32 random bytes, base64. Keep an existing one: it opens the sealed connection rows. |
| `DASHBOARD_ORIGIN` | a var in `wrangler.jsonc` (already set) |
| `GITHUB_APP_SLUG` | the App's slug; only a fallback: the API reads the slug from GitHub's `GET /app` (cached an hour), so renaming the App needs no change |
| `GITHUB_APP_CLIENT_ID` | the App's client id (also the JWT issuer) |
| `GITHUB_APP_CLIENT_SECRET` | the App's client secret |
| `GITHUB_APP_PRIVATE_KEY` | the App's private key as PKCS#8 PEM |
| `GITHUB_WEBHOOK_SECRET` | optional for Connect; webhooks answer 503 without it |

GitHub's key download is PKCS#1 (`BEGIN RSA PRIVATE KEY`). The script converts it; by hand:
`openssl pkcs8 -topk8 -nocrypt -in downloaded.pem -out app.pkcs8.pem`.

## Steps (a person)

1. Merge the change that adds `INTEGRATIONS_CALLBACK_ORIGIN` and wait for the
   `deploy-development` and `deploy-dashboard-staging` jobs of `backend.yml` to pass.
2. As a manaflow-ai owner, from a checkout of `feat-cmux-next`:
   `bun backend/apps/api/scripts/dev-github-app.ts create`, open `http://127.0.0.1:3011/`,
   click Create, then Create GitHub App on GitHub. The script writes the slug, client id,
   client secret, PKCS#8 key and webhook secret to
   `~/.secrets/cmux-next-integrations-development.json` (0600) and prints names only. The code
   GitHub returns lives one hour.
3. `cd backend/apps/api && bunx wrangler secret list --env development` (names only). If
   `INTEGRATIONS_KEK` is missing:
   `openssl rand -base64 32 | bunx wrangler secret put INTEGRATIONS_KEK --env development`.
   Never replace an existing one.
4. `bunx wrangler secret bulk ~/.secrets/cmux-next-integrations-development.json --env development`.
5. Check: signed in to a DEV build on the `dev` Cloud environment,
   `GET /v1/integrations/github/status?team=<team>` reports GitHub configured. Connect GitHub
   from the folder menu, install `cmux-cloud-dev` on a test repository, and the browser returns
   to the DEV build, which shows the repository. A connect started from a chat ends on the
   staging console's "Connected to the development Cloud".
