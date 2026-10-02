# Caffeinate (`cmux/caffeinate`)

Keeps the Mac awake: until you stop it, for a time, or while a terminal's command runs (a build, a test run, a long agent turn). Each option of the macOS `caffeinate` tool is explained in plain words, with its flag for people who know it. A cup in the status item shows that something keeps the Mac awake and how long is left; a pane lists what runs with Stop.

The app never spawns a process and never runs `caffeinate`. It asks the host for IOKit power assertions through the proposed host capability `power.assertion.*` (below) and follows the stream `power.assertion.watch`. The app does not poll; its only timer is one-shot, at the next moment a countdown text changes.

Status: prototype. The host capability does not exist yet; the app shows "Keeping awake is not available" until it does. Tests and previews use a fake host and invented fixtures; no test creates a real power assertion.

## Contributions

| Id | Kind | What |
| --- | --- | --- |
| `menu` | status item (`statusStrip` today; `menuBar` proposed, gap 1) | the variant's glance and dropdown |
| `caffeinatePane` | pane kind (`renderPane`) | running assertions with time left and Stop, plus the variant's controls |
| `keepAwake`, `keepAwakeHour` | commands (palette, status item) | the two presets that need no input |
| `start` | command with arguments, MCP tool | every preset: `cmux apps run cmux/caffeinate#start --args '{"preset":"duration","minutes":90}'` |
| `stop`, `stopAll` | commands (stopAll in palette and status item) | stop one (`{"assertion":"pwr_…"}`) or every one the caller may stop |
| `list` | command, MCP tool | JSON: title, kinds, flags, time left, binding, owner |
| `show` | command (palette) | opens the pane (proposed action `app.pane.open`) |
| `cycleVariant` | command (palette, DEV only): "Next Caffeinate Variant" | design switch |

Settings: `variant` (DEV only).

## Scopes

| Scope | Why |
| --- | --- |
| `power:read` | list assertions and follow `power.assertion.watch` (proposed scope) |
| `power:write` | create and release assertions when the user picks a preset or Stop (proposed scope) |
| `terminal:read` (optional) | find the terminals that run a command (`terminal.list`, `terminal.process.get`) for "While a command runs" |
| `mcp:expose` (optional) | `start`, `stop`, `stopAll`, `list` as tools for agents |
| `actions:run` (optional) | open the pane |

## Options in plain words

| Kind | Flag | Shown as | Explanation in the app |
| --- | --- | --- | --- |
| `display` | `-d` | Display | The display stays on. |
| `idle` | `-i` | Mac | The Mac does not sleep when idle. The display can still turn off. |
| `disk` | `-m` | Disks | Disks do not sleep when idle. |
| `system` | `-s` | Mac on AC power | The Mac does not sleep at all while on power. On battery this does nothing. |
| `user` | `-u` | Wake display | Tells the Mac you are active: the display wakes. Lasts 5 seconds unless you set a time. |

Time limit = `-t` (minutes in the app, seconds on the wire). End with a process = `-w pid`; the app prefers a terminal handle, which ends exactly with the command and cannot be confused by pid reuse.

## Presets (`src/presets.ts`, pure)

| Preset | Kinds (default) | Params |
| --- | --- | --- |
| `command` "Keep awake while this build runs" | `idle` (the build needs the Mac, not the display) | `until: {terminal, end: "command"}`, else `{task}`, else `{pid}`; optional `timeout_s` as a cap |
| `untilStopped` "Until I stop it" | `display`, `idle` | no timeout |
| `hour` "For 1 hour" | `display`, `idle` | `timeout_s: 3600` |
| `duration` (custom) | `display`, `idle` | `timeout_s: minutes × 60`, 1 minute to 24 hours |

Kinds can be overridden (`kinds`). `user` alone without a time gets `timeout_s: 5`, as `caffeinate -u`. `reason` defaults to "cmux Caffeinate: <title>" and is what `pmset -g assertions` shows.

## Variants

| Variant | Status item | Pane |
| --- | --- | --- |
| `menu` (default, recommended) | cup + soonest time left ("42m", "On", "Off"); click opens a dropdown: Until Stopped, 1 Hour, a "Keep Awake For" submenu (15 m to 8 h), a "While a Command Runs" submenu with one item per terminal that runs a command, Stop per assertion, Stop All, Show Caffeinate | header + running list with Stop, then the presets as rows, duration chips, and the running commands |
| `pane` | cup + time left; click opens the pane; right-click has Stop per assertion | every option as a toggle with its explanation and flag; duration chips (until stopped, 15m, 1h, 2h, other minutes); "End early when": never, a command ends (pick a terminal), a process exits (pid); Keep Awake; running list |

Recommendation: `menu`. Keeping the Mac awake is a two-second action, and the three presets cover almost every use without a pane; the build preset is one pick in a submenu that names the running command. Strongest objection: the dropdown hides what each preset holds (display vs Mac vs AC power), so a user who wants the display off during a long build must find the pane or the `kinds` argument; and the command submenu is read on mount and on Refresh only, so it can be out of date until the host gets a terminal foreground stream (gap 6). `pane` explains every option but costs a pane and four choices for the common case.

Screens (preview harness, not committed): (`<variant>-active-{dark,light}`, `<variant>-idle-dark`, `<variant>-unavailable-dark`, `<variant>-status-{active,idle,unavailable}-dark`, `menu-idle-commands-light`, `pane-idle-command-light`).

## Power assertions: proposed host capability `power.assertion/1`

Owner: the native host on the machine whose power state changes (the macOS app's host service on that Mac; later the daemon's native helper). It holds IOKit assertions itself (`IOPMAssertionCreateWithProperties`, `IOPMAssertionDeclareUserActivity`), one IOKit assertion per kind, named with the request's `reason`. No process is spawned. On a host without the capability (Linux daemon, iOS, web) `list` answers `{available: false, unavailable_reason: "power.unsupported_platform"}` and `create` fails with `power.unsupported_platform`.

| Op | Params | Result | Risk | Scope |
| --- | --- | --- | --- | --- |
| `power.assertion.create` | `{kinds: ["display"\|"idle"\|"disk"\|"system"\|"user"], reason: string ≤ 120, timeout_s?: 1..86400, until?: {terminal: "terminal_…", end?: "command"\|"close"} \| {task: "task_…"} \| {pid: int}, until_label?: string}` | `{assertion: "pwr_…", expires_at: RFC 3339 \| null, revision}` | mutate-own | `power:write` |
| `power.assertion.release` | `{assertion: "pwr_…"}` or `{all: true}` | `{released: ["pwr_…"], revision}` | mutate-shared | `power:write` |
| `power.assertion.list` | `{}` | `{revision, available, unavailable_reason?, power_source: "ac"\|"battery"\|"unknown", assertions: [record], limits: {max_per_app, max_timed_s}}` | read | `power:read` |
| stream `power.assertion.watch` | filter `{}` | events below | read | `power:read` |

Record: `{assertion, kinds, reason, created_at, expires_at, until, until_label, owner: {actor, origin: "user"\|"script"\|"agent", app}, inactive_kinds}`. `until_label` is the host's display text for the handle ("make · api"). `inactive_kinds` lists kinds the host holds but macOS ignores now (`system` on battery).

Watch events, each with a decimal-string `revision` (strictly increasing per host; clients drop events at or below the revision they have): `{type: "created"|"updated", assertion: record}`, `{type: "released", assertion: id, cause: "user"|"timeout"|"until"|"owner_disabled"|"owner_uninstalled"|"host_restart"|"replaced"}`, `{type: "power", power_source, available, inactive: [{assertion, kinds}]}`, and `{type: "reset", ...list result}` after a reconnect.

Rules:

- Binding. `until.terminal` with `end: "command"` (default) ends when the command running in that terminal's foreground at create time exits (the host records the foreground process group and its start time, then waits on exit with a kqueue `NOTE_EXIT`, no polling); with no command running, create fails with `power.terminal_idle`. `end: "close"` ends when the terminal closes. `until.task` ends when the task reaches a final state. `until.pid` (origin user only) ends on `NOTE_EXIT`; the host checks the process start time so a reused pid never extends an assertion. A handle the caller cannot read fails with `scope.missing`.
- Who may do what. Origin user: anything. An agent or script (`actor` agent or app without a gesture): only `until.terminal` equal to the caller's own terminal, and only `timeout_s` up to 4 hours (else `power.not_permitted`). Release: the owner (same actor), or origin user for anyone's. `{all: true}` releases what the caller may release. For an app op called through MCP or the CLI, the host evaluates the original caller (gap 3), not the app.
- Limits. 8 live assertions per app and 32 per host (`power.limit`); timed assertions at most 24 hours (`power.bad_timeout`); untimed ones need origin user. `user` alone without `timeout_s` lasts 5 s.
- Lifecycle. The host releases an app's assertions when the app is disabled, uninstalled or its grant for `power:write` is revoked (cause `owner_disabled`/`owner_uninstalled`), and all of them when the host process exits (IOKit releases a dead process's assertions; on restart nothing is restored and clients get `reset`). Assertions do not move between machines.
- Sleep and lid. An assertion prevents idle sleep only. Closing the lid without an external display, choosing Sleep, low battery, or thermal emergency still sleep the Mac; `system` has no effect on battery (`inactive_kinds`, `power` event). Timeouts count wall-clock time: on wake the host releases expired assertions at once (cause `timeout`). A `user` declaration wakes a sleeping display, never a sleeping Mac.
- Errors: `power.unsupported_platform`, `power.not_permitted`, `power.limit`, `power.bad_timeout`, `power.terminal_idle`, `power.handle_gone`, `power.not_found`, `operation.unsupported`, `scope.missing`.
- Idempotency: create takes an idempotency key (the CLI's `--request-id`); release is idempotent (`power.not_found` after a release counts as done in the app).

Why existing ops do not suffice: no op holds a power assertion, and an app may not spawn `caffeinate`; the owner must be the host that can call IOKit and see process exits.

Other proposed operations: `app.pane.open {kind, gesture}` (action, macOS client, open the pane; shared with other apps).

CLI verbs requested from the CLI owner: `cmux power keep-awake`, `cmux power list`, `cmux power stop` (the v2 generators would produce them from the fragment).

## Platform v2

`cmux-app.v2.json` and `catalog/caffeinate-catalog.json` sketch the app on the converged model: app ops in a catalog fragment owned by `app:cmux/caffeinate` (V1) with palette, CLI (`power keep-awake`, `power list`, `power stop`) and MCP surfaces; places as interfaces `cmux.status/1` with `placement: "menuBar"` and `cmux.pane/1` (V2); terminal and task handles (V6); a `variants` block, `strings/`, gesture tokens on `show` (V11); `requires.hostCapabilities: ["power.assertion/1"]` and `lifecycle.onDisable: "release-owned"` (proposed keys).

## Platform gaps (most important first)

1. No menu bar placement: the schema allows `titlebar`, `roomBar`, `statusStrip`. Proposal: `cmux.status/1` with `placement: "menuBar"` (an `NSStatusItem` that hosts the scene). The prototype declares `statusStrip`.
2. No host capability for power (`power.assertion.*` above) and no manifest key to declare one (`requires.hostCapabilities`) or to tie it to the app lifecycle.
3. Commands do not know who invoked them: `__cmuxAppRunCommand` passes `{app}` only. The agent rule (own terminal only, stop only own) needs `ctx.invoker {actor, origin, terminal}` and `ctx.gesture`; the host must also evaluate the original caller when an app op forwards to a host op. The app checks `ctx.invoker` when present (`src/policy.ts`); the host stays the authority.
4. No command context handle: "Keep Awake While This Command Runs" in the palette needs the terminal it was opened from (`$context.terminal` in the fragment).
5. A gesture token is spent by the first mutation, so Stop All must be one op (`release {all: true}`); a batch rule for gestures is not defined.
6. No stream for a terminal's foreground process (`terminal.watch` or a `foreground` field in a terminal event): the running-command list is read on mount and on Refresh.
7. No relative-time text: countdowns cost one VM wakeup per change (one-shot timer). Proposal: `Text` with `relativeTo` and `style: "countdown"`.
8. No `Toggle` and no multi-line `Row` subtitle: the option list is custom stacks; Row subtitles are one line.
9. `Menu` takes a text title only; the status item cannot be just a symbol that opens the dropdown.
10. `accent` renders like `primary` in the preview; the "on" cup is not tinted.
11. No app i18n in today's hosts: `strings/en.json` and `strings/ja.json` are bundled; `cmux.t` answers first when a host passes strings.
12. `x-cmux-devOnly` (setting and `cycleVariant`) is not honored yet; proposed ops are rejected locally unless the scope table lists them; the validator warns on `power:*`.

## Development

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/caffeinate          # build dist/main.js
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/caffeinate
bun test first-party-apps/caffeinate/test
bun first-party-apps/caffeinate/preview/build.ts                                      # preview fixtures, times relative to now
```

Preview fixtures: `active.json` (a 1-hour assertion, one bound to a running build, one until stopped with its AC-power part paused on battery), `idle.json`, `unavailable.json` (no capability). `strings/en.json` is generated from the `t()` calls (test/l10n.test.ts checks it).
