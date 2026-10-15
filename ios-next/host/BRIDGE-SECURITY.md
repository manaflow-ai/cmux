# cmux-next-host bridge: security analysis

`cmux-next-host run` bridges the phone into the cmux-next app running on the
same Mac (`--bridge auto|on|off`, default `auto`). This is a remote relay into
the app's daemon and its acpmux agent service, so it follows the repo's
remote-relay rules (`skills/cmux-socket-policy/references/remote-relay-authorization.md`):
default deny, an explicit allowlist, no command-bearing params, scoped IDs, and
policy tests.

## Who is on the other end

The phone reaches the host over a WebRTC link that the backend only
establishes for the account that paired this Mac (host token, per-session
family checks, revocation; see `PROTOCOL.md` §5). The phone is the Mac owner's
own device. In standalone mode the same link already gets full terminals
(`$SHELL -l`) and agents on this Mac. The bridge must not give the phone more
than that, and must not let a compromised phone or link widen it.

## What the bridge talks to

| Target | How it is found | Local power |
| --- | --- | --- |
| cmux-next daemon | `$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-<uid>/cmux-app[-<tag>].sock`, or `--daemon-socket` | A same-uid Unix client is fully trusted by the daemon (it includes admin commands such as `shutdown-daemon`, `pairing-response`, `run`). |
| acpmux | `~/.acpmux[/tags/<tag>]/acpmux.sock`, or `--acpmux-socket` | The Unix socket has acpmux's `Local` origin: start any harness, any cwd, MCP servers, peers, import/export. |

Both sockets give far more than the phone needs. The bridge therefore never
forwards phone JSON. Each phone RPC (`term.*`, `agent.*`) is mapped in host
code to fixed daemon/acpmux calls with host-built params, and every outgoing
call is checked by `src/bridge/policy.ts` before it is written (a second,
independent gate). Anything not listed there is refused.

## Allowlist

Daemon (`DAEMON_ALLOW`), with the only fields each may carry:

| Command | Fields | Why |
| --- | --- | --- |
| `identify`, `set-client-info` | `name`, `kind:"frontend"`, `capabilities`, `device_kind`, `device_name` | handshake |
| `subscribe` | `tree_events:"deltas"` | terminal list changes made on the Mac |
| `list-workspaces` | none | terminal list (pty tabs only are exposed) |
| `attach-surface` | `surface`, `mode:"bytes"`, `cols`/`rows` (2 to 1000) | mirror a terminal; `cols`/`rows` only for a terminal the phone created (see Sizing) |
| `set-size-counts` | `surface`, `counts:false` only | the phone's view never takes a Mac terminal's grid |
| `resize-attached-view` | `surface`, `lease`, `cols`/`rows` (2 to 1000) | the phone's grid for its own view of a terminal it created |
| `note-size-activity` | `surface` | that view takes the grid (the daemon's `latest` policy) |
| `send` | `surface`, `bytes` (base64, 1 MiB) | typing into an existing terminal |
| `detach-attached-view` | `surface`, `lease` | end a mirror |
| `new-tab` | `cols`/`rows` (2 to 1000) | a new tab running the user's default shell, at the phone's grid |
| `close-tabs` | `surfaces` (exactly one), `end_terminals:true` | `term.close`: close the tab and end its shell (plain `close-surface` left the pty running for the daemon's 30 s reap grace) |
| `rename-surface` | `surface`, `name` | phone terminal rename |
| `select-workspace`, `select-screen` | `index` | `layout.focusTab`: bring the pane's workspace/screen forward |
| `focus-pane` | `pane` (numeric) | `layout.focusTab` |
| `select-tab` | `pane` (numeric), `index` | `layout.focusTab` |
| `new-frontend-browser-tab` | `url` (http/https without credentials, or `about:blank`), `engine:"cef"` | `browser.create` while mirroring the Mac's browser: a new tab in the active pane |

acpmux (`ACPMUX_ALLOW`): `initialize` (empty client capabilities),
`_acpmux/watch`, `_acpmux/sessions`, `_acpmux/harnesses`, `_acpmux/models`,
`session/new` (`cwd`, `mcpServers: []`, `_meta.acpmux.{harness, model}` only),
`_acpmux/attach`, `session/prompt` (text and image blocks only),
`session/cancel`, `_acpmux/kill`, `_acpmux/permission_respond`,
`session/set_model`, `session/set_mode`, `_acpmux/rename`.

## The three questions

### Can it execute commands or open content on local objects?

- **Typing into a terminal (`send`).** Yes, by design: the phone types into
  the user's own shell, exactly what the standalone host's PTYs already
  allow. The bridge adds no new execution surface. It can only reach
  terminals that already exist on this Mac, and only through the
  phone's own paired, family-checked link.
- **Spawning terminals.** Only `new-tab` with no params. The daemon runs
  the user's default shell (`SHELL`) in the inherited working directory.
  `shell_args`, `cwd`, `env`, `argv`, `command`, `terminal_id` and launch
  specs are denied on every command. `run`, `create-terminal`,
  `create-surface-with-receipt`, `apply-layout`, `split`, `new-pane*` and
  `new-screen` are not listed at all. `term.create` with a `cwd`, or with
  any option other than the ignored `cols`/`rows` (`argv`, `env`,
  `shell_args`, `command`, ...), is refused with `unsupported`. The daemon runs on this Mac, which is the intended
  target: there is no other host a spawn could fall back to (verified live
  on mini-cmux15, see below).
- **Agents.** `session/new` starts a harness that acpmux already knows
  (claude, codex, ...) with no extra argv or env. `mcpServers` must be empty,
  so the phone cannot make acpmux spawn an MCP server command. `cwd` must be
  an existing directory inside `$HOME` (`safeCwd`). `_meta.acpmux` may carry
  only `harness` and `model`, so no policy, preset, env or person key can be
  passed. Prompts carry text and images only. `resource` blocks (which can
  name local files) are refused.
- **Permission approvals.** acpmux accepts an "allow" only from a
  connection that presented the app's per-launch person key, which the
  bridge does not have. The phone can deny or cancel; an allow returns
  acpmux's `permission.person_required` error. `_acpmux/set_policy`,
  `_acpmux/set_rules` and `_acpmux/defaults` are denied, so the phone cannot
  widen what agents may do without asking. acpmux also refuses permission
  widening through `session/set_mode` without the person key.
- **Opening content.** Browser verbs are not bridged. The Mac's browser
  tabs are frontend-rendered and the daemon cannot stream them. The host
  keeps its own Chrome provider for `browser.*`.

- **Layout and focus (`layout.get`, `layout.focusTab`).** Read-only tree
  plus selection: `select-workspace/screen/tab` and `focus-pane` move the
  Mac's shared focus to a tab the phone picked (requested behaviour: phone
  and Mac stay in step). They execute nothing and create, close, split,
  move or resize nothing. `delta` selectors and every layout mutation
  (`split`, `close-pane`, `move-tab`, `set-split-ratio`, ...) stay denied.
  The pane and tab must exist in the current tree (`not_found` otherwise),
  and only numeric ids are accepted.

- **Mac browser tabs (`browser.mac.v1`).** Only when the user turns on
  the cmux-next setting "Allow cmux on iPhone to view browser tabs" (off by
  default). The app then writes `~/Library/Application Support/cmux-next/devtools.json`
  with the CEF DevTools port and its pid. The host adopts the endpoint only
  when all of these hold:
  - the file is owned by this user and not readable by group or others
    (0600);
  - the pid is a running app bundle that ships the cmux-tui daemon
    (cmux-next);
  - the endpoint answers `/json/version` on `127.0.0.1`. The host builds
    the URL as `http://127.0.0.1:<port>`; no host name from the file is
    used.

  The file is the app's own (`~/Library/Application Support/<bundle id>/devtools.json`,
  written by `CEFRemoteDevTools`). The host acts only on `state:"ready"`, and
  never on `restartRequired`, even if a port was seen earlier. The host
  re-checks the file on change and every 5 s, and drops the connection when it
  turns off. Panes are paired with targets only through the mapping the app
  publishes; nothing is guessed from URL or title. `browser.attach
  bringForward:true` (phone opt-in) and "Show on Mac" use the same
  allowlisted `layout.focusTab` selection. The app window keeps its own tab
  selection, so for a browser tab the host also runs the validated app's
  bundled CLI with a fixed argv (`<app>/Contents/Resources/bin/cmux browser
  <tab_…> select`, no shell, tab id must match `tab_[0-9a-f]+`, app path from
  the pid that wrote `devtools.json` and passed the cmux-next check). It only
  selects an existing tab.
- **New Mac browser tab (`browser.create` while mirroring).** It calls
  `new-frontend-browser-tab` with only `url` and `engine:"cef"`. The URL
  must be http(s) without user info, or `about:blank`; `file:`,
  `javascript:`, `chrome:` and every other scheme are refused, as are
  `pane`, `profile_id`, `owner` and idempotency keys. Opening a web page is
  what the phone's New Tab does in the host's own Chrome too; the tab lands
  in the Mac user's active pane, where they can see it. It sends no `--remote-allow-origins`-style
  Origin and connects only to loopback. Through it, the phone can see and
  drive (input, navigate, reload) the Mac user's tabs, which is what the
  setting grants. It never creates, closes or activates a Mac tab, never
  brings one to the front, and never overrides its viewport or user agent,
  so what the Mac shows is unchanged.

### Can it mutate or destroy objects it does not own?

The daemon and acpmux run as this macOS user and hold only this user's
terminals and sessions. All are the phone owner's objects. IDs are scoped:

- `terminalId` must be `s<surface>` for a surface that is currently a
  **pty tab** in the daemon's tree. Browser, conversation and unknown
  surfaces are `not_found`. Ref forms and other shapes are rejected.
- Agent session ids are passed to acpmux, which only knows this user's
  sessions. `agent.list` hides sessions that live on acpmux peers.
- `term.close` and `agent.close` act on the user's own objects, as the
  existing mobile daemon-lane policy already allows (`term.close` uses
  `close-tabs` with `end_terminals` so the shell ends with the tab).

### Does it read local state the phone has no business seeing?

The phone sees what the cmux-next window shows:
- the terminal titles, cwd and grid;
- the terminal bytes (the scrollback replay included);
- agent transcripts, including tool input and output.

The bridge does not call `list-terminals` or `resolve-terminal`, which expose
`launch_spec` (argv, env). It does not read daemon or acpmux config, tokens,
peers, exports or Chief homes. No daemon admin or local-admin command is
reachable.

## Sizing

The phone never resizes a terminal opened on the Mac. Those attaches carry
no size, the bridge's view is set to `counts:false`, and `term.resize` from
the phone is answered with the Mac's current grid (`term.updated`) instead
of resizing. The phone renders at the Mac's grid.

A terminal the phone created (`term.create`, remembered in memory for the
bridge's lifetime) opens at the phone's grid and is sized by the phone: its
attach carries the phone's grid, its view counts toward sizing, and
`term.resize` reaches the daemon through that view's own lease
(`resize-attached-view`, then `note-size-activity`). Under the daemon's
default `latest` policy the side that was active last sets the grid, so
using the tab on the Mac takes it back. The bridge never sends
`resize-surface`, and never sizes a terminal it did not create.

## Tests

`test/bridge.test.ts`:
- **Daemon policy:** denies `run`, `create-terminal`,
  `create-surface-with-receipt`, `apply-layout`, `split`, `shutdown-daemon`,
  `pairing-response` and `agent-session-*`. Also denies `new-tab` with `cwd`,
  `shell_args` or `env`; render mode; grids outside 2 to 1000; `counts:true`;
  relay sub-views (`view`) on `resize-attached-view`; wrong
  id types; extra fields; and prototype keys.
- **acpmux policy:** denies peers, import/export, policy/rules/defaults and
  shutdown. Also denies `session/new` with MCP servers or extra `_meta`
  fields, `resource` prompt blocks, and non-empty client capabilities.
- **Mac browser** (`test/macBrowser.test.ts`): setting states (absent,
  off, group/other-readable file, dead pid, silent port, invalid JSON, on).
  Also: no activate, bring-to-front, viewport, user-agent or reload calls on
  attach; create, close and activate refused; tabs dropped when the setting
  turns off.
- **Layout** (`test/layout.test.ts`, `test/bridge.test.ts`): split-tree
  rects, tab mapping, focus commands allowed only with numeric ids, and layout
  mutations (`split`, `close-pane`, `move-tab`, `set-split-ratio`, `delta`
  selection) denied.
- **Bridges against fake daemon and acpmux sockets:** owned-target allow
  cases, refusal of browser and malformed terminal ids, `cwd` refusal,
  no resize on the wire, and transcript mapping.
