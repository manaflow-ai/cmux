# Usage (`cmux/usage`)

Usage of every AI plan account the user's routers know: Claude, Codex and the other providers (keyed providers too). For each provider it shows a summary line: the pace verdict (under pace, on pace, over pace), the burn ratio, the actual and ideal burn in percent per hour, and how many accounts are usable. For each account it shows the router's label and state, the 5-hour and weekly percent left, both reset countdowns, extra usage money, and the account's own pace. It lives in the menu bar (status item), a pane with every provider and account, and a sidebar section with one line per provider.

The app never runs a process and never sees a credential. Its server, `cmux-usage serve`, runs the router's status command and keeps the history the pace needs; the app reads it through `account.list`, `account.usage` and the stream `account.watch`. The app does not poll.

Status: prototype. The server and the operations below do not exist yet; the app shows "Usage server not available" until they do. Tests and previews use invented fixtures (no real labels, ids or emails).

## Contributions

| Id | Kind | What |
| --- | --- | --- |
| `menu` | status item (`statusStrip` today; `menuBar` proposed, gap 1) | the variant's glance; a click opens a dropdown with one summary line per provider, Refresh Now and Show Usage |
| `usagePane` | pane kind (`renderPane`) | every provider (collapsible group, summary line, verdict badge) and every account |
| `usage` | sidebar section (default region bottom) | one line per provider |
| `show` | command (palette, status item, section) | opens the pane (proposed action `app.pane.open`) |
| `refresh` | command (palette, status item, section) | asks the server to read the routers now (it rate-limits) |
| `status` | command, MCP tool via `mcpServers` | JSON for agents: `cmux apps run cmux/usage#status --args '{"provider":"claude"}'`; account rows only with `"accounts": true` |
| `cycleVariant` | command (palette): "Next Usage Variant" | DEV/NIGHTLY design switch |

Settings: `variant` (DEV only), `notifications` (default on), `staleMinutes` (default 30).

## Scopes

| Scope | Why |
| --- | --- |
| `account:read` | read account usage and history from the usage server (proposed scope) |
| `account:write` | ask for a read now when the user clicks Refresh (proposed scope) |
| `notification:write` | one notice when a provider has no usable account left |
| `mcp:expose` (optional) | the `status` tool for agents |
| `actions:run` (optional) | open the pane from Show Usage |

Local storage (always allowed) keeps the notice history and the variant override.

## Pace (`src/pace.ts`, pure)

Per provider, at the reading time of the server:

- Accounts in state `error` do not count.
- Ideal burn = the sum over counted accounts of `weekly_left_pct / hours to that account's weekly reset` (percent per hour that uses every account's weekly headroom exactly by its reset).
- Actual burn = the drop of `weekly_left_pct` between this reading and the newest reading at least 30 minutes older (`account.usage {before_ms, limit: 1}`), per hour. Accounts are matched by provider and id. An account whose weekly reset passed or moved between the two readings, or that is in only one of them, is left out, so a reset never shows as negative burn.
- Verdict: under pace when actual / ideal < 0.8 ("raise load"), over pace when > 1.2 ("lower load"), else on pace. "pace in 30m" while no older reading exists; "no headroom" when the ideal burn is 0.
- Usable = state not `cooked`, `temp` or `error`. Counts show usable of all accounts.

Per account: the share of the window used divided by the share of the window that has passed (same bands), for the weekly window (7 days) and the session window (5 hours); shown from 5 percent of the window on.

## Variants

| Variant | Menu bar | Pane | Section |
| --- | --- | --- | --- |
| `rows` (default, recommended) | gauge glyph tinted by the worst verdict + "Cl ×1.00 · Cx ×1.40" (burn ratio per metered provider; "Cl 4/7" usable of total while the pace waits) | per provider: collapsible header with verdict badge, summary line; one native row per account ("in use · 5h 41% · 2h 10m · wk 58% · 2d 4h · pace ×0.61", badge = weekly left) | one row per provider: verdict and ratio, badge usable/total |
| `meters` | one tiny bar per metered provider (weekly headroom left over all its accounts), tinted by the verdict | per provider: headroom bar, summary line; one line per account with session and weekly bars | provider bar, usable count, verdict |
| `quiet` | empty while every provider is on or under pace; a warning glyph + "Cx ×1.40" when one is over pace or out of usable accounts | dense monospaced table, one line per account (label, state, 5h, week, pace) | one monospaced line per provider |

Recommendation: `rows`. The burn ratio is the number that tells the user what to do (raise or lower parallel work), the native rows scale to about a hundred accounts, and the pane reads like the router's own status. Strongest objection: with 2 metered providers the menu bar text is about 16 characters wide, and the ratio means nothing until 30 minutes after the first reading ("Cl 4/7" before that), so the glance changes meaning; `meters` stays narrow but cannot be read exactly, and `quiet` costs no space but gives no glance while things are fine.

## Data shape

`account.list` result: the router status schema (`sr status --json`, schema version 1), normalized by the server, plus an envelope.

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-10-02T12:00:00Z",
  "fetched_at_ms": "1790942400000",   // when the router last answered (decimal string)
  "stale": false,                     // the server missed its own reads
  "error": null,                      // {code, message}: the last read failed; providers are the last good reading
  "sources": [{ "id": "subrouter", "ok": true, "error": null }, { "id": "coderouter", "ok": true, "error": null }],
  "providers": {
    "claude": {
      "accounts": [{
        "id": "claude_acct_1", "label": "alder", "provider": "claude", "plan": null,
        "state": "active",            // error | cooked | temp | active | rec | protected | ready
        "session_left_pct": 41, "session_reset_at": "2026-10-02T14:10:00Z",
        "weekly_left_pct": 58, "weekly_reset_at": "2026-10-04T16:00:00Z",
        "extra_usage_usd": null,
        "source": "subrouter"         // added by the server
      }],
      "summary": { "usable": 4, "total": 7, "weekly_left_sum_pct": 173 }
    }
  }
}
```

`account.usage` result: `{snapshots: [{taken_at_ms, accounts: [{provider, id, state, weekly_left_pct, weekly_reset_at}]}]}`, newest first.

The labels are the router's labels, shown as the router shows them. The server never adds emails or tokens; the `status` command returns labels only with `accounts: true`.

## Server (`cmux-usage serve`, proposed)

Manifest block (needs the server schema of the platform branch plus `instances` and `data: "cache"`, gaps 2 and 3): `{kind: "native", binary: "cmux-usage", args: ["serve"], catalog: "catalog/account-catalog.json", hosts: ["local"], instances: "machine", data: "cache"}`. One instance per machine that has the app; it owns `account.*` (owner `app:cmux/usage`).

- Sources. The local router CLI: `sr status --json` (90 s timeout, no shell, fixed argv, the user's PATH from the login environment). It answers from the configured router server or the hosted service and reports `server`. Pooled accounts of the hosted router that the local router does not list come from the catalog op `coderouter.accounts.usage` (owner `cloud:coderouter`), called with the user's principal, never with a key of the server's own. Accounts are merged by provider and id; the fresher reading wins; each keeps `source`.
- Demand. The server counts open `account.watch` streams by their `demand` filter and the mount's visibility (gap 7). `detail` visible (pane or section): read when the last reading is older than 60 s, then every 2 minutes. `glance` only: every 5 minutes while the user is active, 15 minutes after an hour without input. No visible subscriber, screen locked, display asleep or Low Power Mode: no reads at all. One-shot deadlines, no repeating timer.
- Errors. Exponential backoff 1, 2, 4, 8, 16, 30 minutes with jitter. A failed read keeps the last good reading with its `fetched_at_ms` and sets `error`; `stale` after two missed periods. A missing router binary is `router.missing` and stops reads until the binary appears (file system event).
- History. One compact snapshot per successful read (`provider, id, state, weekly_left_pct, weekly_reset_at`), kept 8 days, thinned to one per 10 minutes after 24 hours. Cache class: never synced, deleted on uninstall.
- `account.refresh` coalesces with a read in flight and allows one read per 30 s.
- Logs never contain labels.

The old design (a host service that reads each agent CLI's credential files and calls the providers' usage endpoints) is removed: the router already owns the accounts and their credentials.

## Proposed operations

| Name | Params | Result | Owner | Risk | Scope | Invalidated by | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `account.list` | `{provider?}` | data shape above | `cmux-usage serve` (per machine) | read | `account:read` | `account.watch` | nothing exposes router accounts; the app may not spawn `sr` |
| `account.usage` | `{before_ms?, since_ms?, provider?, limit?}` | snapshots, newest first | `cmux-usage serve` | read | `account:read` | `account.watch` | the pace needs a reading 30 minutes older; only the owner that reads the router can keep that history |
| `account.refresh` | `{wait?}` | `{accepted, next_allowed_at_ms}` | `cmux-usage serve` | mutate-own | `account:write` | emits on `account.watch` | a user-initiated read, rate-limited by the owner |
| stream `account.watch` | filter `{demand: "glance" \| "detail"}` | `{revision}` per new reading | `cmux-usage serve` | read | `account:read` | | push instead of polling; the filter is the demand signal |
| trigger event `account.exhausted` | | `{provider, total}` | `cmux-usage serve` | read | `account:read` | | the out-of-accounts notice belongs to the owner (once per machine, also when no surface is open); the app sends it until then |
| `app.settings.set` | `{key, value}` | `{value}` | config layer, validated against `contributes.settings` | mutate-own | none | settings push | `cycleVariant` must persist the variant; today it falls back to a storage override |
| action `app.pane.open` | `{kind, gesture}` | `{pane}` | macOS client (layout of the focused workspace) | mutate-own, user origin only | `actions:run` | | `show` must open the pane |

CLI verbs requested from the CLI owner: `cmux usage get --json`, `cmux usage refresh` (the v2 catalog generators would produce them from the fragment below).

## Platform v2

`cmux-app.v2.json` and `catalog/account-catalog.json` sketch this app on the converged model (app-platform plan section 12): ops in a catalog fragment owned by `app:cmux/usage` (V1), places as interfaces `cmux.status/1`, `cmux.section/1` (V2), server with `instances: "machine"` (V10), a `variants` block and `strings/` (V11), and a gesture token on `usage.show` (V11). The CLI paths in the fragment (`usage get`, `usage history`, `usage refresh`, `usage watch`, `usage status`) are what the v2 generators would produce. Today's runtime loads only `cmux-app.json`.

## Platform gaps (most important first)

1. No menu bar placement. Proposal: `cmux.status/1` with `placement: "menuBar"`, an `NSStatusItem` whose button hosts the scene; a primary click opens the item's `Menu` items or a popover. The prototype declares `statusStrip`.
2. Server schema: `server` exists only on the platform branch, with `data: durable | ephemeral`; this app needs `data: "cache"` and `instances: "machine"` (V10 names them, the schema does not have them yet).
3. Server process rights: the server must run one user binary (`sr`). v2 has no rule for a server spawning a process; proposal `server.scopes: {"process:spawn:sr": reason}`, enforced by the server's OS sandbox profile, shown in consent.
4. No pane interface in v2: V2 lists `cmux.status/1` and `cmux.section/1`, not a pane; the sketch uses `cmux.pane/1`.
5. No visibility signal. A mount cannot tell whether it is on screen, so the server cannot stop reads for hidden surfaces. Proposal: the host forwards mount visibility with each stream subscription.
6. No relative-time text. Countdowns cost one VM wakeup per minute while a surface is mounted (one one-shot timer at the next change). Proposal: `Text` props `relativeTo` and `style: "countdown" | "age"`.
7. No tinted meter and no container width: bars are rectangles of fixed width (status item, meters cards) or untinted `ProgressView`s. Proposal: `Meter {value, tone, marks}` that fills its container (V7 lists `Meter`).
8. No table: the `quiet` pane pads monospaced text into columns, which breaks for wide characters. Proposal: `Table` (V7).
9. `Menu(title, items)` takes a static item list; the live dropdown uses `.contextMenu(fn)`.
10. No app i18n: `src/l10n.ts` holds English and Japanese; v2 `strings/` and `cmux.t` replace it.
11. Proposed ops are rejected locally with `scope.missing` unless the host's scope table lists them; the validator warns on `account:*`.
12. Every command becomes an MCP tool; `cycleVariant` carries `"mcp": false` as a proposal (v2: `variants` block).
13. `x-cmux-devOnly` on a setting is not honored yet.
14. An empty status item still takes its slot (`quiet`); the host should hide an empty status item.

## Development

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/usage          # build dist/main.js
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/usage
bun test first-party-apps/usage/test
bun first-party-apps/usage/preview/build.ts                                      # preview fixtures, times relative to now
```

Preview fixtures: `normal.json` (Claude on pace with an account in error, Codex over pace, one keyed provider), `pending.json` (no older reading), `stale.json` (47 minutes old, router timeout), `source-error.json` (the hosted router failed), `unavailable.json` (no server), `empty.json` (no accounts).
