# Status indicators

Status: design + phase 1 build, status-indicators lead, 2026-10-02. Binding: OWNERSHIP-PRINCIPLES.md,
architecture.md, actions.md. Inputs: Lawrence's request (2026-10-02): "add the loading indicator so it's
built into cmux as well, i like the thinness. but want to make loading customizable too, with like the
native macos spinner. think of ergonomic api for this, like wait for command, or imperative, think about
what users/agents might want". Related: workspace status/progress/log v2 ops (#16174,
`cmux-tui-core::state::workspace_status_store`), the agent status pipeline (hook helper -> journal ->
record reducer -> `agent-status` on the tab), sidebar sections (sidebar-sections.md).

## 1. What people want

| Who | Wants | Answer |
| --- | --- | --- |
| Someone running a long command | see it is still running from another workspace; know when it ends and whether it failed | automatic busy from shell integration; `cmux status run -- cmd` adds a label, a done/failed badge and a notification with the duration |
| A script or Makefile | say "Building 3/10" without caring which tab it runs in | `cmux status set --label "Building" --progress 0.3`; target defaults to the caller's terminal; the status dies with the terminal or the process |
| A program that already prints progress | nothing to do | OSC 9;4 (ConEmu / Windows Terminal progress, emitted by winget, cargo-nextest, some npm/pnpm builds, systemd tools) becomes a determinate ring |
| An agent (Claude, Codex) | show "working", "needs approval" with zero setup; wait for another terminal or job | hooks already report working/blocked; `cmux status wait <key>` and `cmux terminal <term> wait --until idle|exit|prompt|output RE` block on events |
| Someone who dislikes motion or the arc | pick the native macOS spinner, a dot, or nothing; size, line width, color | `appearance.statusIndicator.{style,size,thickness,color}`, Reduce Motion respected |

## 2. Rendering (client; landed)

One component, `CmuxNextDesign/StatusIndicator`:

- `StatusIndicatorState`: `idle | busy(progress?) | paused(progress?) | waiting | error | success`.
- `StatusIndicatorStyle`: `arc` (default, the thin 72% arc), `native` (NSProgressIndicator's spokes, rendered
  once per pixel size by AppKit, alpha-normalized and used as a tinted mask, rotated in 8 discrete steps like
  the control), `dot` (pulsing dot), `none` (no loading mark; waiting/error/success still show).
- Known progress always draws a still ring (track + clockwise arc from 12 o'clock), in every style except
  `none`; the AppKit determinate circular indicator is the same shape. Paused uses the attention color.
- `StatusIndicatorPlan.make(state, style:, animates:)` is the pure rule table (tested). `StatusIndicatorLayer`
  executes a plan with at most two sublayers that exist only while needed; all motion is Core Animation in
  the render server (spin, step, pulse), removed when the plan has none: idle, hidden, occluded or Reduce
  Motion indicators cost no frames and no wakeups. `StatusIndicatorView` wraps it for view hosts.
- `StatusIndicatorAppearance`: one app-wide `Observations` sequence over settings + tunables pushes config
  changes to registered hosts (no task per row).
- Colors come from the theme (Ghostty-derived): loading = secondary text, waiting = attention,
  error = danger, done = success; `appearance.statusIndicator.color` overrides the loading color. No blue.

Tabs: the icon slot shows the strongest loading report only (`StatusMapping.loading`); waiting, error and
done stay on the tab badge, so an agent waiting for approval never hides another source's spinner there.
Known gaps: busy tabs in an occluded window still animate (render-server frames, no wakeups); a busy tab
costs 2 layers (container + arc; ring and native 3).

Used by: sidebar workspace rows and collapsed group headers (`ActivityIndicatorView` deleted), the tab strip
icon slot (the tab spinner layer), and available to sections (sidebar-sections lead renders it on
`SidebarItemInfo` items), Home and pane headers.

Settings (`cmux.json`, Settings > Appearance > Loading Indicator): `appearance.statusIndicator.style`
(`arc|native|dot|none`), `.size` (0.5...1.5 of the slot), `.thickness` (0.5...4 pt), `.color` (`#RRGGBB` or
`theme`). Debug Settings > Status Indicators: style override (compare variants live), arc length, ring track
opacity, dot size, pulse low opacity, native steps. Style precedence: Debug override, then the reporter's
hint (`--style`), then the setting.

## 3. Stacking (client; landed)

Several sources can report about one target. `StatusStack.resolve` orders reports by:

1. state: error > waiting > busy > paused > success;
2. among equal states, known progress beats indeterminate (it says more);
3. source: explicit (`status set`) > run (`status run`) > agent hook > OSC 9;4 > browser loading > inferred
   command;
4. newest, then id (total order, property-tested).

The indicator shows the first report (and its style hint); the hover card and VoiceOver list all of them in
that order ("Tests · 40%", "Claude: working"). A workspace rolls up its tabs plus its own entries; a
collapsed group rolls up its workspaces.

## 4. Ownership (who writes which fact)

| Fact | Owner | Role | Lifetime |
| --- | --- | --- | --- |
| Agent working/blocked | session host (agent hook record reducer, existing) | terminal fact | hook events; cleared on session end and terminal exit |
| Terminal progress (OSC 9;4) | session host | terminal fact | `9;4;0`, next OSC 133;A prompt, terminal exit |
| Command running (shell integration 133 C..D) | session host | terminal fact | command end, exit; shown only after `status.inferBusyAfter` (default 3 s) |
| Status entries (`status set`, `status run`) | workspace store (`workspace_status` rows of #16174) | shared state | explicit clear; TTL; owner pid exit; owner terminal exit; agent session end; all decided by the daemon in the same commit as the cause |
| Browser loading | the Mac app showing the page (browser runtime) | client runtime | page load events |
| Merge, style, color, animation | client | view | |

The client never infers death or clears a stale entry itself; it renders the owner's facts.

## 5. API (daemon + Rust CLI; accepted by the #16174 owner 2026-10-02, not landed)

Ops extend the v2 status ops instead of adding a parallel table:

- `workspace_status.set` gains optional `state` (`busy|success|error|waiting|info`, absent = info so today's
  callers are unchanged), `progress` (0...1, busy only), `style` hint, `ttl_ms`, `owner {pid?, terminal?,
  agent_session?}`, `target_terminal` (`term_…`). Idempotent by key (and the mutation's idempotency key).
- `owner` is daemon-validated: `terminal` must be a `term_` id the session host knows; `pid` is accepted only
  from a local trusted client and recorded with the machine id, never from a remote client.
- Daemon-owned auto-clear: TTL (one-shot timer), owner pid exit (kqueue `NOTE_EXIT`, local host), owner
  terminal exit, agent session end; decided by the owner in the same commit and emitted as a `state_delete`
  with its own transaction (no client timers). Default owner when the CLI runs in a cmux terminal is
  `$CMUX_TUI_TERMINAL_ID`, so a closed terminal never leaves a spinner; `--keep` opts out.
- Terminal facts behind capability `terminal-activity-v1`: `progress {state: normal|error|indeterminate|paused,
  value?}` parsed from the raw OSC 9;4 string the session host already keeps (`terminal_metadata.rs`
  `osc_progress`, never published today) and `busy {command?, since_ms}` from the existing `ShellMark`
  CommandStart/CommandEnd. Written only by the session host on the terminal record, never stored as status
  rows.

CLI (noun-first; target defaults to the caller's terminal, else `current` workspace):

```
cmux status set [KEY] --label T [--target ws_|tab_|term_|current] [--state busy|success|error|waiting|info]
                [--progress 0.4|40%] [--style arc|native|dot|none] [--ttl 30s] [--pid N | --keep] [--json]
cmux status clear [KEY] [--target ...] [--all]
cmux status list [--target ...] [--json]            # raw entries and terminal facts, merged order
cmux status run [--label T] [--target ...] [--notify auto|always|never] [--badge-ttl 8s] -- CMD ...
cmux status wait KEY [--target ...] [--timeout D]   # 0 success/cleared, 1 error, 124 timeout
cmux terminal <term_…> wait --until idle|exit|prompt|output RE [--timeout D]   # next to the existing terminal wait verbs
```

- `KEY` defaults to `cli:<terminal>`, so repeated `status set` calls from one terminal replace each other.
- `status run`: sets busy owned by its own pid (a killed CLI clears it), runs the command with the terminal's
  stdio, forwards SIGINT/SIGTERM, then writes success/error with the duration and a badge TTL, posts a
  notification when the run took at least 10 s (`auto`), and exits with the command's status.
- All verbs go through `spec/resource-operations-v2.json`, so MCP and mux tools get them from the same
  catalog, with parity cases in the CLI coverage test. Waits subscribe to events; nothing polls.
- Who writes it: the status-indicators lead, on a branch off `feat-cmux-next-acpmux` with a PR into it (the
  #16174 owner reviews and merges); new code in new modules (every cmux-tui file is at its god-file baseline);
  extend `workspace_status.*` in `cmux-tui-core::state` with commit-before-publish and reducer invariant tests.

## 6. Prototypes

Gallery (every style x state at 12 pt and 32 pt, dark and light, plus the demo sidebar in each style):
`Tests/CmuxNextSidebarTests/StatusIndicatorGalleryTests.swift`, run with `CMUX_STATUS_GALLERY=<seconds>`.
Live switching: Debug Settings > Status Indicators > Style override. Recommendation: keep `arc` as the default
(thinnest, reads as chrome), offer `native` for people who want the system look, `dot` for minimal motion.

## 7. Phases

1. Shared indicator, plan, stack, settings, tunables; sidebar rows, group headers and tabs migrated; agent
   hook status mapped (`StatusMapping`). *(landed)*
2. Daemon ops and terminal facts (section 5), Rust CLI verbs (PR into feat-cmux-next-acpmux), then Swift
   decoding of `workspace_status` and `terminal-activity-v1` into `StatusMapping` reports after the pin cut.
3. Pane header and Home adoption; hover card detail list; sections items (sidebar-sections lead).

## 8. Open decisions for Lawrence

- Default style: arc (recommended), native or dot.
- Reporter style hints beat the user's setting (current). Alternative: the setting always wins and hints are
  ignored.
- `none` hides loading but keeps waiting/error/done marks (current). Alternative: hide everything.
- Inferred busy for plain shell commands: on after 3 s (proposed), or off by default.
- `status run` notification threshold: 10 s (proposed).
