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
| GUI capability gate | `DaemonIdentity.supports(_:)`, `DaemonCapabilities.shared` (required + optional) | built; the GUI hides a feature when the daemon lacks its capability |
| Required set | `DaemonCapabilities.required`: a daemon without one is refused | built |
| Local daemon upgrade | `DaemonLauncher.handOffIfStale` at app launch: other build -> fenced `shutdown-daemon`, terminals adopted | built, automatic, lossless |
| Stale local daemon after launch | `QuietDaemonUpdate` (CmuxNextDaemonService): every handshake (launch and each reconnect, bundled build read again) checks the build and the app's capabilities; a stale daemon is handed off (`handOffForUpdate`) at a quiet moment, or after 2 minutes at the first moment no app request is in flight, then health-checked | built, automatic, terminals survive; Debug toggle `cmuxTUI.restartStaleWhenQuiet` ("Update a stale cmux-tui automatically", on) |
| Unresponsive local owner | `UnresponsiveOwnerWatch` (CmuxNextDaemon) in `DaemonRecovery`: plain `ensure` failing as a stuck owner for 30 s and 2+ times in a row runs `server ensure --replace-unresponsive` without the confirm, once per owner process | built, automatic, terminals survive; Debug toggle `cmuxTUI.restartUnresponsive` (on) |
| Capability handoff | `handOffForCapability` (page listener) | built, one capability |
| acpmux upgrade | `AcpmuxVersionHandoff` + `AcpmuxQuietHandoff`: a daemon of another build is handed off at every lookup (launch and reconnect) once no session runs a turn or waits on a permission; one without agent hosts (an older build) is replaced too and its chats resume from disk; one with agent hosts waits at most 10 minutes (a deadline at the cap wakes the wait, so it needs no event or reconnect); the next daemon must report the bundled build within 5 s (one retry, then the "acpmux did not start" banner) | built, automatic; Debug toggle `agent.replaceStaleAcpmuxWhenQuiet` (on) |
| Unresponsive acpmux | `AcpmuxUnresponsiveWatch`: status calls missing their deadline 3 times over 20 s, then a 5 s confirm, SIGTERM (agent hosts survive and are adopted), SIGKILL after 10 s; once per pid. The process is known by its pid and start time, checked again before each signal, and its exit watch is armed before SIGTERM: a reused pid is never signalled | built, automatic; Debug toggle `agent.restartUnresponsiveAcpmux` (on) |
| Chief's cmux-tui daemon | `cmux-chief-*` never upgrades until it restarts (`update-keeps-sessions.md` 2.3) | open |
| Remote daemons (Mac mini, VM, Cloud) | `DaemonService` connects through `cmux link dial`; same `identify` | no upgrade path, no notice |

So skew that the app cannot fix silently already happens: a dev or unknown-build daemon
(`build_commit` nil, handoff skipped), a refused handoff, an acpmux without agent hosts, the Chief's
daemon, and every remote daemon. Today the matching features just disappear with no explanation.

## 2. Rules

1. **Background app downloads stay as they are** (user, Oct 20). No "Preparing update %" pill;
   a240 owns the update card and loading flow.
2. **Never auto-restart a server when a restart loses anything.** The lossless handoffs are
   automatic: the local daemon at launch; acpmux with agent hosts (agents survive); and a stale
   local cmux-tui found at any later handshake, at a quiet moment or after 2 minutes (2a: its
   terminals survive; an attached chat or TUI exits and is reopened, a cut turn resumes). Everything
   else asks: a toast, then a confirm.

   2a. **The local cmux-tui restarts by itself, when quiet or after 2 minutes.** A cmux-tui of another build than the
   bundled one (or, build unknown, without capabilities the app uses) is not left behind a new app:
   `QuietDaemonUpdate` checks every handshake, the first one and each reconnect's, against the
   bundled build read again each time (the app may be updated in place while it runs), and hands
   the daemon off with the same `handOffForUpdate` path as the toast's button. Its terminals survive:
   `shutdown-daemon` without `end_terminals` leaves every terminal host running and the new daemon
   adopts it (durable-sessions.md section 3), and `DaemonConnection.quietHandoff` holds the app's
   own requests until the new daemon answers. The work it can cut is a client that does not
   reconnect: a `cmux` CLI or MCP call in flight (a local client with no kind; the CLI reports an
   error, MCP a retryable failure), a `cmux chief` chat (it exits; its history is on disk and the
   next `cmux chief` opens it, an unsent draft is lost) or a TUI (it exits; its terminals keep
   running and `attach` shows them again), and a conversation turn (resumed by the daemon,
   #23921). So for up to 2 minutes from when the daemon was first found stale
   (`Pacing.quietWaitCap`) it waits for a quiet moment, all of: the person gave no input for 60 s
   or the app is in the background, no menu, drag or resize tracking runs, no request of the app's
   connection is in flight, and `OwnerIdleProbe` (`.reconnecting`) finds no such client and nobody
   typing. The app's own `frontend` connections (each terminal view, the page relay), other apps
   and pages reconnect by themselves and do not count. Our owner is hardly ever idle that way (an
   open chat or TUI stays attached between turns), and a stale daemon must not wait forever (Leo,
   2026-10-21: accept that it breaks, and resume what it interrupted). So after the cap only the
   momentary part counts: it hands off at the first moment no app request is in flight and no
   menu or drag runs, trying again every 5 s while one does (`Pacing.momentRetry`); the person and
   attached clients no longer hold it. Before the cap it tries again on owner events
   (`client-detached`, `client-changed`, typing), when the app goes to the background, and on a
   deadline once a minute. The toast stays hidden while it waits. At most once per daemon process
   and bundled build, three times per launch.

   Health check: the next daemon must connect with the bundled build within 90 s. If none connects
   the reconnect is woken and it waits once more; if one of another build connects it is restarted
   once more (quietly). A second failure shows "Couldn't restart cmux-tui: ..." and the toast with
   its manual Restart, and no more automatic restarts run until a daemon of the bundled build connects.

   2b. **An unresponsive local owner restarts by itself.** When plain `server ensure` keeps failing
   the way a stuck owner makes it fail (restore bound passed, no answer, `server.unavailable`) for
   30 s and at least twice in a row, `DaemonRecovery` runs the button's `server ensure
   --replace-unresponsive` without its confirm, once per owner process and three times per launch.
   An owner that refuses at its connection limit (`server.busy`) answers and is never killed by this
   path; the button stays for it. Terminal hosts are separate processes: they outlive the replaced
   owner and the next owner adopts them.
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
serve (`DaemonCapabilities` optional set minus `unservedByBundledDaemon`), or when its build differs
from the bundled one (a notice with no feature list; for the local cmux-tui it shows only when its
quiet restart cannot run, rule 2a). Required capabilities never reach
this path (a daemon without them is refused before attach, as today).

## 4. Feature catalog

`ServerFeatureCatalog` maps capabilities to a short localized feature name ("Tab groups", "Saved tab
groups", "Workspace checklists", "Browser profiles", "Pinned workspaces", ...). Only capabilities a
person can see are listed; the rest are counted. The toast names up to three, then "and N more".
The catalog lives next to the strings (21 locales) and has a test that every listed capability is a
real `DaemonCapabilities` optional capability.

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
- The button opens the confirm; nothing restarts from the toast without the confirm. For the local
  cmux-tui the toast stays hidden while its automatic restart (2a) waits; it shows when that restart
  is refused or impossible (an external binary, the toggle off) or failed its health check. A build that differs with no capability missing gets the
  generic "Restart cmux-tui to use new features" with no feature list.
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
