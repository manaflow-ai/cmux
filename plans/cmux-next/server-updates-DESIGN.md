# Server updates: restart cmux-tui or acpmux to use new features

Status: design, 2026-10-20 (subagent "Separate server updates"). User (Oct 20), after Rex's screenshots:
the app updates on its own, in the background, as today (keep it); what cmux-next lacks is Rex's
"Restart the server to use new features [Restart Server…] [x]" prompt and its confirm, and Rex's
better Liquid Glass on toasts, prompts and the bottom-left tips.

Builds on: `version-skew.md` (CLI/daemon/app skew, `identify` build id), `daemon-capabilities.json`
(the capabilities the GUI relies on), `durable-sessions.md` section 3 and `update-keeps-sessions.md`
(handoff keeps terminals and agent hosts, a248), `updates-and-announcements.md` (UpdateFlow, cards),
a256's `cmux version --json`, a240's update card and loading flow, a274's motion gate.

"Mitchell's protocol stuff": the only Mitchell Hashimoto note in the repo is OSC 7501
(`osc7501-conformance.md`). The rule we take from Ghostty/libghostty practice is the same one
cmux-tui already follows: **feature detection by capability, never by version comparison**. A
client asks "does the server advertise `tab-groups-v1`?", not "is the server >= 0.66?". Version
numbers only order builds for display; capabilities decide behavior. No new design is needed on the
wire for cmux-tui; this doc adds the user-facing half.

## 1. What exists today

| Piece | Where | State |
| --- | --- | --- |
| Handshake | cmux-tui `identify`: `version`, `build_commit`, `protocol_version` (12), `capabilities[]` | built |
| GUI capability gate | `DaemonIdentity.supports(_:)`, `DaemonCapability` (required + optional) | built; the GUI hides a feature when the daemon lacks its capability |
| Required set | `DaemonCapability.required`: a daemon without one is refused | built |
| Local daemon upgrade | `DaemonLauncher.handOffIfStale` at app launch: other build -> fenced `shutdown-daemon`, terminals adopted | built, automatic, lossless |
| Capability handoff | `handOffForCapability` (page listener) | built, one capability |
| acpmux upgrade | `AcpmuxVersionHandoff`: hand off only when the daemon runs agent hosts; otherwise **keep it running** ("its agents would end") | built; the kept daemon never upgrades and nothing tells the user |
| Chief's cmux-tui daemon | `cmux-chief-*` never upgrades until it restarts (`update-keeps-sessions.md` 2.3) | open |
| Remote daemons (Mac mini, VM, Cloud) | `DaemonService` connects through `cmux link dial`; same `identify` | no upgrade path, no notice |

So skew that the app cannot fix silently already happens: a dev or unknown-build daemon
(`build_commit` nil, handoff skipped), a refused handoff, an acpmux without agent hosts, the Chief's
daemon, and every remote daemon. Today the matching features just disappear with no explanation.

## 2. Rules

1. **Background app downloads stay as they are** (user, Oct 20). No "Preparing update %" pill;
   a240 owns the update card and loading flow.
2. **Never auto-restart a server when a restart loses anything.** The existing lossless handoffs stay
   automatic (local daemon at launch: terminals survive; acpmux with agent hosts: agents survive).
   Everything else asks: a toast, then a confirm.
3. **Capabilities, not versions.** The gate is "the server advertises X". The app keeps working on
   the older protocol: every optional capability already has a fallback (the feature is hidden).
4. **Name what you gain.** The toast lists the user-visible features the restart turns on (the
   feature catalog, section 4); capabilities with no user-visible feature count as "and N more".
5. **Say what survives and what is lost** in the confirm, per server and per state (section 5).
6. One shared action path for every entry point: toast button, Cmd+Shift+P, CLI, MCP
   (`server.restart`, `server.status`).

## 3. Handshake

`ServerHandshake` (CmuxNextUpdater, a pure value) = server kind (`cmux-tui` | `acpmux`), host
(`local` | remote host name), build (commit), protocol version, and the advertised capability set
(nil when the server advertises none: acpmux today).

- cmux-tui: from `identify` (`DaemonIdentity`): nothing new on the wire.
- acpmux: from `_acpmux/status` (`build`, `agentHosts`). Step 4 adds `capabilities[]` to
  `_acpmux/status` (crate `acpmux`, `status.rs`), the same shape as `identify`; until then an acpmux
  skew is "another build" with no feature list.
- Remote hosts: the same `identify` through `cmux link dial`; the handshake carries the host name, so
  each host gets its own notice. A remote restart runs that host's own `cmux server restart` over the
  link (step 5); the bundled-binary check never applies to a remote host.

The app side: `ServerSkewPolicy.notice(for:appCapabilities:bundledBuild:)` returns a
`ServerUpdateNotice` when the server lacks capabilities this app can use and its build is known to
serve (`DaemonCapability` optional set minus `unservedByBundledDaemon`), or, for a server that
advertises nothing, when its build differs from the bundled one. Required capabilities never reach
this path (a daemon without them is refused before attach, as today).

## 4. Feature catalog

`ServerFeatureCatalog` maps capabilities to a short localized feature name ("Tab groups", "Saved tab
groups", "Workspace checklists", "Browser profiles", "Pinned workspaces", ...). Only capabilities a
person can see are listed; the rest are counted. The toast names up to three, then "and N more".
The catalog lives next to the strings (21 locales) and has a test that every listed capability is a
real `DaemonCapability` optional capability.

## 5. Restart impact (the confirm's text)

| Server | Kept | Lost |
| --- | --- | --- |
| cmux-tui (local) | every terminal, its shell, running programs and scrollback; layouts, tabs, workspaces | a short reconnect (about a second); a CLI command running at that moment fails and can be rerun |
| acpmux with agent hosts | every agent session and its history; agents keep running | a Chief or agent turn in flight may stop (a185 owns Chief turn resume) |
| acpmux without agent hosts (older build) | chat history on disk | **running agents end**; their in-flight turns are lost |
| remote cmux-tui | as local, on that host | as local, on that host |

The confirm (CmuxDialog, the shared glass dialog): title "Restart cmux-tui?", the kept and lost
lines, [Cancel] [Restart]. Restart is the default button only when nothing is lost; when agents
would end it is marked destructive.

## 6. Toast

One toast per server and host, shown once per app launch per server build:

> Restart cmux-tui to use new features: Tab groups, Workspace checklists and 3 more
> [Restart cmux-tui…] [x]

- It stays until acted on (no timeout); x snoozes that server build for 24 hours. A new server
  build (or a new app build with more capabilities) is a new notice.
- The button opens the confirm; nothing restarts without the confirm.
- After a restart the app re-reads the handshake: the new capabilities turn on and the notice ends.
  A restart that still lacks them (an external binary) says so in a toast and does not loop.
- Motion: the toast's appear and slide go through the shared motion path (`CmuxToastMotion`);
  a274's category gate files them under "menus/cards/toasts" when it lands.

## 7. Entry points (one path)

- Cmd+Shift+P: "Restart cmux-tui…", "Restart acpmux…" (open the confirm), "Server Status".
- CLI: `cmux server status` (exists; adds `missing_capabilities` and `restart_gains` to `--json`),
  `cmux server restart [--acpmux] [--yes]` (step 3: stop keeping terminals, then `ensure` from this
  CLI's bundle; prints the same kept/lost lines and asks unless `--yes`).
- MCP: the catalog actions become `app_server_restart` / `app_server_status` like every catalog
  action; an agent call never skips the confirm unless the person allowed it (`--yes` is the human
  CLI's only).
- a256's `cmux version --json` gains a `servers[]` array with each server's build, protocol and
  `missing_capabilities`.

## 8. Liquid Glass for toasts, prompts and tips (user, Oct 20)

Rex draws its toast and confirm as neutral gray glass: real blur, a soft top-lit specular rim,
continuous corners, a light shadow, correct in light and dark. Ours: the toast is an opaque theme
surface by an earlier rule; dialogs are theme-tinted glass without a rim; sidebar cards are a flat
13% text fill.

One shared style, `FloatingGlassStyle` (CmuxNextDesign), used by all three and by a201's gray glass
pill (share it, do not fork):

- material: Liquid Glass on macOS 26+, vibrancy before, opaque under Reduce Transparency (as today);
- tint: **neutral** (no theme hue): white veil on dark, black veil on light, alpha from the style;
- rim: a 1 px inside stroke, a vertical gradient (brighter top, faint bottom), per appearance;
- corners: continuous; toast 9 pt, dialog `Metrics.panelCornerRadius`, card `Metrics.space3`;
- shadow: one soft elevation-2 shadow (toast, dialog); none for in-sidebar cards.
- motion: not part of the style. One place, `MotionTunables`: popups use `popover` (response
  0.25 s, damping 0.86, from 0.95) and `popoverClose` (0.16 s, critically damped, to 0.97); toasts
  use `appear` plus `fadeIn`/`fadeOut`. All fade the card layer, never the window alpha.

Gallery: four looks (today, A "Rex neutral", B "neutral + stronger rim", C "theme tint + rim") for
toast, confirm and tip in light and dark, in a Home right-pane tab; A ships (Recommended).

## 9. Steps

1. This doc; gallery (`design/server-updates-gallery.html`, shown in the right pane).
2. Failing tests first (CmuxNextDesignTests, CmuxNextUpdater tests via CmuxNextAppTests):
   version skew -> capability off + notice listing features; restart -> capability on, notice gone;
   x snoozes; nothing restarts without confirm; toast uses glass (not opaque) with a rim unless Reduce
   Transparency. Then the fix: model, coordinator, toast and confirm, `FloatingGlassStyle` on toast,
   dialog and sidebar cards; strings in 21 locales.
3. `cmux server restart` and `server status --json` additions (cmux-tui CLI).
4. `_acpmux/status` advertises `capabilities[]`; acpmux notices list features.
5. Remote hosts: notices per host; restart over the link.
6. Chief's own cmux-tui daemon: notice in the Chief card (with a185's turn resume, never mid-turn).

## 10. Settings > Server (Oct 23, user: "we need these in cmux when it makes sense", Rex's server panel)

Rex's Settings server panel (name, Running, version line, "Restart Recommended", Local API URL,
Tailscale address with Pair, Stop) maps onto cmux-next like this:

| Rex | cmux-next | State |
| --- | --- | --- |
| Bottom toast "Restart the server to use new features" | `ServerUpdatePresenter` toast (sections 6, 7) | built (a286) |
| Running / version line | Settings > Server row: `Version 0.67.0 · Build abc1234 · Protocol 12` from `identify` | built here |
| "Restart Recommended" + Restart… | the row shows while the policy finds missing capabilities; ignores snooze; the button opens the toast's own confirm (`cmux.settings.server.restart`) | built here |
| API revision "server supports 0 to 0, app speaks 0 to 1" | not shown: cmux-tui `identify` reports one `protocol_version` and capabilities decide behavior (rule 3), so there is no range to compare | by design |
| Local API URL + copy | Local Socket + Copy (the connected daemon's socket) | built here |
| Tailscale Address + Pair + copy | first address of `cmux host status --json` (`addresses`) + Pair (opens the Server panel's pairing card) + Copy | built here |
| Stop Server… | not added: the only stop is `server.stopServing` (debug-only, turns off serving); stopping cmux-tui itself would end terminals | open |
| acpmux row | the report lists any server the coordinator heard from; acpmux reports no handshake yet (step 4) | open |

Data path: `ServerUpdateCoordinator.settingsReport` (pure, tested) -> `ServerSettingsPageJSON` ->
host lists `server` -> `ServerCard.tsx`. Nothing in the report restarts a server.

