# Authentication Patterns

Log in to a site in a cmux browser tab from a script. Related:
[session-management.md](session-management.md), [../SKILL.md](../SKILL.md).

Set `TAB` from [surface discovery](surface-discovery.md) or from the result of
`cmux tab create browser`. Never guess a tab or log credentials.

## Basic login

```bash
TAB="$(cmux --json tab create browser --url https://app.example.com/login | jq -r '.. | .id? // empty | select(startswith("tab_"))' | head -n1)"
[ -n "$TAB" ] || { printf '%s\n' 'tab create did not return a tab id' >&2; exit 1; }
cmux browser "$TAB" snapshot --interactive
cmux browser "$TAB" fill e1 "$APP_USERNAME"
cmux browser "$TAB" fill e2 "$APP_PASSWORD"
cmux browser "$TAB" click e3
cmux browser "$TAB" state
```

Waits are not supported yet, so the CLI cannot block until the dashboard
loads. Check `state` once the user or the page is done; if the URL still shows
`/login`, take a new snapshot and report what the page says.

## OAuth, SSO and two-factor

Drive the fields you can see with `snapshot`, `fill` and `click`. Let the user
finish the provider step or the 2FA code in the tab, then confirm with
`cmux browser "$TAB" state`. There is no timed wait for the return URL.

## Saved state and cookies

The per-tab CLI has no cookie commands; the browser REPL has them
([repl-guide.md](repl-guide.md)). `page.context().clearCookies()` returns
`{ restoreIds }` and `page.context().restoreCookies(result)` undoes it; you
never delete the backup (only the person can). The tab keeps its login in the browser profile for
as long as the profile keeps its cookies. To clear site data for the focused
browser, the UI action `cmux browser delete-site-data` exists; check its
arguments with `cmux action describe "browser delete-site-data"`.

## Security

Take credentials from environment variables. Do not print `snapshot` or `text`
output from authenticated pages into logs or chat without filtering it.
