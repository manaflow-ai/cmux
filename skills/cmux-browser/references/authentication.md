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

Block until the dashboard loads with
`cmux browser "$TAB" wait --url-contains /dashboard --timeout-ms 15000`. If it
times out and `state` still shows `/login`, take a new snapshot and report what
the page says.

## OAuth, SSO and two-factor

Drive the fields you can see with `snapshot`, `fill` and `click`. Let the user
finish the provider step or the 2FA code in the tab, then confirm with
`cmux browser "$TAB" state`, or wait for the return URL with
`wait --url-contains`.

## Saved state and cookies

The per-tab CLI reads and sets cookies (`cookies get|set|clear`, see
[commands.md](commands.md)). For an undoable clear use the browser REPL
([repl-guide.md](repl-guide.md)): `page.context().clearCookies()` returns
`{ restoreIds }` and `page.context().restoreCookies(result)` undoes it; you
never delete the backup (only the person can). The tab keeps its login in the browser profile for
as long as the profile keeps its cookies. To clear site data for the focused
browser, the UI action `cmux browser delete-site-data` exists; check its
arguments with `cmux action describe "browser delete-site-data"`.

## Importing the person's sign-ins from another browser

When a site needs the person's existing login (and they did not ask you to type
credentials), ask for their cookies from the browser they use:

```bash
cmux browser import-cookies --from chrome --domain github.com \
  --reason "Review PR 1234 in the cmux browser as you"
cmux browser import-cookies --from arc:Work --domain linear.app,notion.so \
  --reason "Read the roadmap pages you linked"
cmux browser import-cookies --from safari --domain example.com --reason "…" --profile Work
```

- `--from <browser>[:<profile>]`: a registry id or the app's name (`chrome`,
  `arc`, `brave`, `edge`, `helium`, `dia`, `firefox`, `zen`, `safari`); the
  profile is the browser's folder name or the name it shows. No profile is the
  browser's `Default` profile.
- `--domain`: comma-separated sites. Ask for the fewest you need; without it
  every cookie of that profile is copied.
- `--reason` (required for agents): one sentence on what you will do with the
  login. The person reads it first.
- `--profile`: the cmux browser profile to import into (default: the default
  profile).

The app shows the person a consent panel before it reads anything: it names
your chat or terminal tab (a click shows it), your reason, your latest message,
the source and the sites. Only after Allow does macOS ask for the browser's
password (Chromium) or does cmux need Full Disk Access (Safari). The command
waits up to about 3 minutes and fails with a clear error on Deny or no answer;
do not retry on your own. Cookies never leave the Mac, and you never print them.

## Security

Take credentials from environment variables. Do not print `snapshot` or `text`
output from authenticated pages into logs or chat without filtering it.
