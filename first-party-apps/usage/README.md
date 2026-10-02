# Usage (`cmux/usage`)

Agent plan usage and limits at a glance: Claude Code plans (5-hour session window, weekly window, model-specific weekly limits), Codex/ChatGPT plans (5-hour and weekly), API-key providers (spend against a budget) and CodeRouter pools (usage per pooled account). For every window it shows percent used, the reset countdown ("resets in 2h 10m"), the pace ("runs out in 40m" when the current average rate reaches the limit before the reset) and stale data. It warns once per window at 80 and 95 percent.

The app never sees a credential. A native usage service on the host reads the agent CLIs' sign-ins, calls the providers' usage endpoints and gives the app numbers only (`usage.get`, event `usage.changed`). The service, not the app, decides when to fetch. The app does not poll.

Status: prototype. The usage service and the other operations below do not exist yet; the app shows "Usage service not available" until they do. Tests and previews use invented fixtures.

## Contributions

| Id | Kind | What |
| --- | --- | --- |
| `menu` | status item (`statusStrip` today, `menuBar` proposed: gap 1) | the tightest limit, compact; click opens the dropdown |
| `usage` | sidebar section (default region bottom) | every account and window |
| `show` | command (palette, status item) | reveals the usage section (the popover, once it exists) |
| `refresh` | command (palette, status item, section) | asks the service to refresh now (it rate-limits) |
| `status` | command, MCP tool via `mcpServers` | JSON for agents: `cmux apps run cmux/usage#status --args '{"provider":"codex"}'` |
| `cycleVariant` | command (palette): "Next Usage Variant" | DEV/NIGHTLY design switch |

Settings: `variant` (DEV only), `notifications` (default on), `warnAt` (default `[80, 95]`), `staleMinutes` (default 30).

## Scopes

| Scope | Why |
| --- | --- |
| `usage:read` | read usage numbers from the usage service (proposed scope) |
| `usage:write` | ask for a refresh when the user clicks Refresh (proposed scope) |
| `notification:write` | the 80 and 95 percent warnings |
| `coderouter:read` (optional) | CodeRouter pool usage (proposed scope) |
| `mcp:expose` (optional) | the `status` tool for agents |
| `actions:run` (optional) | reveal the section from Show Usage |

Local storage (always allowed) keeps the warning history and the variant override.

## Variants

| Variant | Menu bar | Detail (section, future popover) |
| --- | --- | --- |
| `menuPercent` (default, recommended) | gauge glyph + "62%" of the tightest window; click opens a plain dropdown listing every window ("5-hour  62%  resets in 2h 10m · runs out in 1h 44m"), Refresh Now, Show Usage | native rows: window, reset and pace subtitle, percent badge tinted at the thresholds |
| `menuMeters` | a glyph of two tiny stacked meters (session over week) of the account with the tightest limit, no text | one card per account; a meter per window with a tick where a steady pace would be |
| `sidebarOnly` | nothing while every limit is calm; a warning glyph + percent once a limit reaches a threshold | dense lines: label, native progress bar, percent, time to reset (or "↓ 40m" to run-out) |

Recommendation: `menuPercent`. One number is readable at menu bar size, and the dropdown is the native menu every Mac user knows. Strongest objection: one bare percent hides which limit it is (session or week, which provider); the user must open the dropdown or hover to learn that the 87% is the Codex weekly window. `menuMeters` answers that for the session/week pair but cannot be read exactly; `sidebarOnly` costs no menu bar space but gives no glance until something is wrong.

## Data shape (proposed `usage.get` result)

```jsonc
{
  "revision": "7",
  "accounts": [{
    "id": "usage_account_1",          // opaque, stable; never an email
    "provider": "claude-code",        // claude-code | codex | anthropic-api | openai-api | coderouter
    "provider_title": "Claude Code",
    "kind": "plan",                   // plan | api | pool
    "label": "Personal",              // user-chosen; an email only if the user opted in at the service
    "plan": "Max 20x",
    "source": "oauth",                // where the service read it: oauth | cli | admin-api | coderouter
    "fetched_at_ms": "1790000000000",
    "stale": false,                   // the service missed its own refreshes (it knows its cadence)
    "error": null,                    // {code, message, retryable}: "auth.expired", "rate_limited", …
    "windows": [{
      "id": "weekly:opus",            // stable within the account
      "kind": "weekly",               // session | daily | weekly | monthly | budget | credits | other
      "scope": "Opus",                // model-specific limit; null for the main one
      "used_percent": 83,             // or used + limit + unit for spend
      "used": null, "limit": null, "unit": null,   // usd | tokens | requests | credits
      "window_seconds": 604800,
      "resets_at_ms": "1790300000000",
      "label": null                   // English fallback, only for kind "other"
    }]
  }]
}
```

Pace is computed in the app from `used_percent`, `window_seconds` and `resets_at_ms` (linear: expected = elapsed / length; run-out = remaining / average rate; no prediction in the first 5 percent of a window). The service may add `pace` later if it keeps history.

## Proposed operations

| Name | Params | Result | Owner | Risk | Scope | Invalidated by | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `usage.get` | `{provider?, account?}` | data shape above | native usage service in the cmux daemon (per machine); reads the agent CLIs' credentials, which never leave it | read | `usage:read` | `usage.changed` | nothing exposes plan limits; credentials must stay host-side, so the app cannot fetch with `net.fetch` |
| `usage.refresh` | `{provider?, account?}` | `{accepted, next_allowed_at_ms}` | usage service | mutate-own | `usage:write` | emits `usage.changed` | a user-initiated refresh; the owner coalesces it with an in-flight fetch and allows one per account per 30 s |
| event `usage.changed` | subscription filter `{demand: "glance" \| "detail"}` | `{revision, accounts: [id]}` | usage service | read | `usage:read` | | push instead of polling; the filter is the demand signal the cadence uses |
| `coderouter.usage.get` | `{pool?}` | `{pools: [{id, name, accounts: [same account shape]}]}` | CodeRouter cloud (pool owner) | read | `coderouter:read` | `coderouter.usage.changed` | pool accounts live in the cloud, not on this machine |
| `app.settings.set` | `{key, value}` | `{value}` | config layer (`cmux.json` `apps."<id>".settings`), validated against `contributes.settings` | mutate-own | none (own settings) | settings push | `cycleVariant` must persist the variant; today it falls back to a storage override |
| action `sidebar.section.reveal` | `{contribution}` | `{}` | macOS sidebar (client view state: expand and scroll to the section) | mutate-own, user origin only | `actions:run` | | `show` must bring the usage section into view |

## Refresh policy (owned by the usage service)

The app reads on mount (once), on `usage.changed`, and on Refresh. It never schedules a fetch. The service owns the cadence:

- Demand. The service counts live `usage.changed` subscriptions by their `demand` filter, weighted by the host's visibility of the subscribing mount (gap 7). `detail` visible (section or popover open): refresh on open when older than 60 s, then every 2 minutes. `glance` only (menu bar): 5 minutes while the user is active or an agent is working (`agent.list` state `working`), 15 minutes after an hour without input, 30 minutes after four hours.
- Stop. No subscriptions, screen locked, display asleep, or Low Power Mode: no fetches at all. On the next demand it fetches once if the reading is older than that demand's period.
- Errors. Per provider and account, exponential backoff 1, 2, 4, 8, 16, 30 minutes with jitter; a 429 honors `Retry-After`. An auth failure (401, 403, expired token) stops that account until its credential file or Keychain item changes (file and Keychain change events, no retry loop). The service never refreshes a token it does not own: the agent CLI rotates its own refresh token.
- Transient failures keep the last good reading with its original `fetched_at_ms`; the service sets `stale` after two missed periods, and the app also marks a reading stale after `staleMinutes`.
- Mechanics: one-shot deadlines and a shared backoff (no repeating timer), so an idle machine costs zero wakeups.

## Warnings

After each read the app plans warnings (pure `src/alerts.ts`): a window warns when it crosses a higher threshold than the one it already warned for; it re-arms when its reset passes or its percent falls below the lowest threshold. History is keyed by account and window id (providers move the reported reset by seconds between reads) and kept in `cmux.storage`, so an app restart does not repeat a warning. Stale or failed accounts never warn. The top threshold sends an error-level notification.

Objection to keeping this in the app: the app warns only while it runs, and two machines that both run it warn twice. The durable home is the usage service or a notification rule with an owner-side dedupe key (gap 12).

## Platform gaps (most important first)

1. No menu bar placement. Proposal: `statusItems[].placement: "menuBar"`, rendered as an `NSStatusItem` (variable length, height 22) whose button hosts the item's scene; a primary click opens the item's `Menu` items, or a popover contribution (`popovers: [{id, render, width, maxHeight}]`, also opened by `cmux.ui.popover.open(id)`), rendered in an `NSPopover` with the same scene renderer. The prototype declares `statusStrip`, and its "popover" is the sidebar section.
2. No relative-time text. A countdown costs one VM wakeup per minute while a surface is mounted (one one-shot timer at the exact next change). Proposal: `Text` props `relativeTo: <ms>` and `style: "countdown" | "age"`, rendered natively (`Text(timerInterval:)`), zero app wakeups.
3. No meter. Each bar is five `Rectangle`s with fixed widths; `ProgressView` cannot be tinted. Proposal: `Meter {value, tone, marks: [{value, tone}], height}` that fills its container's width.
4. No container width or proportional layout, so meters use fixed widths (240 pt in cards).
5. `Menu(title, items)` takes a static item list. The live dropdown uses `.contextMenu(fn)` on the `Menu` node. Proposal: `Menu` items accept a function.
6. No app i18n or locale API. The app carries English and Japanese tables (`src/l10n.ts`) and reads the locale from `Intl`. Settings titles in `contributes.settings` are English only.
7. No visibility signal. A mount cannot tell whether it is on screen, so it cannot tell the service. Proposal: the host forwards mount visibility with each subscription (or suspends hidden mounts' subscriptions), and `ctx.visible()` for apps.
8. Proposed ops are rejected locally with `scope.missing` unless the host's scope table lists them, and the validator warns on `usage:*` and `coderouter:*` scopes.
9. Runtime: removing a dynamic child decrements the node count by one for the whole subtree, so repeated rebuilds creep toward the 4096-node limit in a long-lived mount. The app makes dynamic children depend on booleans and kinds, not on data or the clock.
10. No `onCleanup` for app code; resources tied to a mount have to be subscriptions or effects created inside it.
11. Every command becomes an MCP tool. `cycleVariant` carries `"mcp": false` as a proposal for per-command exposure.
12. `notification.create` has no dedupe key. Proposal: `dedupe_key` checked by the notification owner across machines.
13. `x-cmux-devOnly` on a setting is not honored yet.
14. An empty status item still takes its slot; the host should hide a status item whose scene is empty (`sidebarOnly`).

## Development

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/usage          # build dist/main.js
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/usage
bun test first-party-apps/usage/test
bun first-party-apps/usage/preview/build.ts                                      # preview fixtures, times relative to now
```

Preview fixtures: `menuPercent.json`, `menuMeters.json`, `sidebarOnly.json` (normal data), `stale.json` (47 minutes old, one sign-in expired), `unavailable.json` (no usage service), `empty.json` (no plans).
