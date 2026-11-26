# Authentication Patterns

Login flows, session persistence, OAuth, and 2FA for cmux browser surfaces. Related: [session-management.md](session-management.md), [../SKILL.md](../SKILL.md).

Set `SURFACE` from [surface discovery](surface-discovery.md) or from the JSON
returned by `browser open`. Never guess a default surface or log credentials.

Saved browser state contains cookies and storage. Use a private directory with
restrictive permissions before saving it:

```bash
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cmux-browser-state"
umask 077
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
STATE_FILE="$STATE_DIR/auth-state.json"
```

## Basic login

```bash
OPEN_JSON="$(cmux --json browser open https://app.example.com/login --focus false)"
SURFACE="$(printf '%s' "$OPEN_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$SURFACE" ] || { printf '%s\n' 'browser open did not return a surface ref' >&2; exit 1; }
cmux browser --surface "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser --surface "$SURFACE" snapshot --interactive
cmux browser --surface "$SURFACE" fill e1 "$APP_USERNAME"
cmux browser --surface "$SURFACE" fill e2 "$APP_PASSWORD"
cmux browser --surface "$SURFACE" click e3 --snapshot-after --json
cmux browser --surface "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 20000
```

## Saving authentication state

```bash
cmux browser --surface "$SURFACE" state save "$STATE_FILE"
chmod 600 "$STATE_FILE"
```

State includes cookies, localStorage, sessionStorage, and open tab metadata for that surface.

## Restoring authentication

```bash
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cmux-browser-state"
umask 077
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
STATE_FILE="$STATE_DIR/auth-state.json"
OPEN_JSON="$(cmux --json browser open https://app.example.com --focus false)"
SURFACE="$(printf '%s' "$OPEN_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$SURFACE" ] || { printf '%s\n' 'browser open did not return a surface ref' >&2; exit 1; }
cmux browser --surface "$SURFACE" state load "$STATE_FILE"
cmux browser --surface "$SURFACE" goto https://app.example.com/dashboard
cmux browser --surface "$SURFACE" snapshot --interactive
```

## OAuth / SSO

Same shape as basic login, waiting on the provider host and then the return host, with generous timeouts:

```bash
OAUTH_STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cmux-browser-state"
umask 077
mkdir -p "$OAUTH_STATE_DIR"
chmod 700 "$OAUTH_STATE_DIR"
OAUTH_STATE_FILE="$OAUTH_STATE_DIR/oauth-state.json"
OPEN_JSON="$(cmux --json browser open https://app.example.com/auth/provider --focus false)"
SURFACE="$(printf '%s' "$OPEN_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$SURFACE" ] || { printf '%s\n' 'browser open did not return a surface ref' >&2; exit 1; }
cmux browser --surface "$SURFACE" wait --url-contains "login.example.com" --timeout-ms 30000
cmux browser --surface "$SURFACE" snapshot --interactive
# fill and click the provider's fields
cmux browser --surface "$SURFACE" wait --url-contains "app.example.com" --timeout-ms 45000
cmux browser --surface "$SURFACE" state save "$OAUTH_STATE_FILE"
chmod 600 "$OAUTH_STATE_FILE"
```

## Two-factor

Drive the password step, let the user complete 2FA in the webview, then wait with a long timeout (`--url-contains "/dashboard" --timeout-ms 120000`) and save state.

## Cookie-based auth

```bash
cmux browser --surface "$SURFACE" cookies set session_cookie "$SESSION_COOKIE"
cmux browser --surface "$SURFACE" goto https://app.example.com/dashboard
```

## Token refresh

Load saved state, navigate, and re-login only when the URL bounced to `/login`:

```bash
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cmux-browser-state"
umask 077
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
STATE_FILE="${STATE_FILE:-$STATE_DIR/auth-state.json}"
: "${SURFACE:?set SURFACE from browser open or surface discovery}"

[ -f "$STATE_FILE" ] && cmux browser --surface "$SURFACE" state load "$STATE_FILE"
cmux browser --surface "$SURFACE" goto https://app.example.com/dashboard

if cmux browser --surface "$SURFACE" get url | grep -q '/login'; then
  cmux browser --surface "$SURFACE" snapshot --interactive
  cmux browser --surface "$SURFACE" fill e1 "$APP_USERNAME"
  cmux browser --surface "$SURFACE" fill e2 "$APP_PASSWORD"
  cmux browser --surface "$SURFACE" click e3
  cmux browser --surface "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 20000
  cmux browser --surface "$SURFACE" state save "$STATE_FILE"
  chmod 600 "$STATE_FILE"
fi
```

## Security

Never commit state files; they contain auth tokens. Take credentials from environment variables. Clear state after sensitive tasks:

```bash
cmux browser --surface "$SURFACE" cookies clear --all
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cmux-browser-state"
STATE_FILE="${STATE_FILE:-$STATE_DIR/auth-state.json}"
OAUTH_STATE_FILE="${OAUTH_STATE_FILE:-$STATE_DIR/oauth-state.json}"
rm -f "$STATE_FILE"
rm -f "$OAUTH_STATE_FILE"
```
