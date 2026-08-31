# Authentication Patterns

Login flows, session persistence, OAuth, and 2FA for cmux browser surfaces. Related: [session-management.md](session-management.md), [../SKILL.md](../SKILL.md).

## Basic login

```bash
cmux browser open https://app.example.com/login --json
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 snapshot --interactive    # e1 email, e2 password, e3 submit
cmux browser surface:7 fill e1 "user@example.com"
cmux browser surface:7 fill e2 "$APP_PASSWORD"
cmux browser surface:7 click e3 --snapshot-after --json
cmux browser surface:7 wait --url-contains "/dashboard" --timeout-ms 20000
```

## Saving authentication state

```bash
cmux browser surface:7 state save ./auth-state.json
```

State includes cookies, localStorage, sessionStorage, and open tab metadata for that surface.

## Restoring authentication

```bash
cmux browser open https://app.example.com --json
cmux browser surface:8 state load ./auth-state.json
cmux browser surface:8 goto https://app.example.com/dashboard
cmux browser surface:8 snapshot --interactive
```

## OAuth / SSO

Same shape as basic login, waiting on the provider host and then the return host, with generous timeouts:

```bash
cmux browser open https://app.example.com/auth/google --json
cmux browser surface:7 wait --url-contains "accounts.google.com" --timeout-ms 30000
cmux browser surface:7 snapshot --interactive
# fill and click the provider's fields
cmux browser surface:7 wait --url-contains "app.example.com" --timeout-ms 45000
cmux browser surface:7 state save ./oauth-state.json
```

## Two-factor

Drive the password step, let the user complete 2FA in the webview, then wait with a long timeout (`--url-contains "/dashboard" --timeout-ms 120000`) and save state.

## Cookie-based auth

```bash
cmux browser surface:7 cookies set session_token "abc123xyz"
cmux browser surface:7 goto https://app.example.com/dashboard
```

## Token refresh

Load saved state, navigate, and re-login only when the URL bounced to `/login`:

```bash
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="./auth-state.json"
SURFACE="surface:7"

[ -f "$STATE_FILE" ] && cmux browser "$SURFACE" state load "$STATE_FILE"
cmux browser "$SURFACE" goto https://app.example.com/dashboard

if cmux browser "$SURFACE" get url | grep -q '/login'; then
  cmux browser "$SURFACE" snapshot --interactive
  cmux browser "$SURFACE" fill e1 "$APP_USERNAME"
  cmux browser "$SURFACE" fill e2 "$APP_PASSWORD"
  cmux browser "$SURFACE" click e3
  cmux browser "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 20000
  cmux browser "$SURFACE" state save "$STATE_FILE"
fi
```

## Security

Never commit state files; they contain auth tokens. Take credentials from environment variables. Clear state after sensitive tasks:

```bash
cmux browser surface:7 cookies clear --all
rm -f ./auth-state.json
```
