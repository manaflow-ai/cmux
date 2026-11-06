# cmux Computer Use

cmux Computer Use lets an agent in cmux see and use desktop apps on the person's
machines: list apps and windows, read accessibility trees, take screenshots, and
click, type, scroll and drag. It is cmux's own implementation, written from
scratch, on macOS, Linux and Windows. It replaces the `cmux-cua` helper (a fork of
trycua/cua), the helper v2 and the upstream cua-driver load; none of them ship
any more.

How we measure it: [evals.md](evals.md).

## Pieces

```
agent (Claude Code, Codex, ...)
  | MCP stdio: tools/list, tools/call
acpmux bridge  -- serves the tool catalog itself; asks the daemon for the endpoint
  | cmux-computer-use-v1 over a local socket (same uid, then the per-launch secret)
Computer Use worker  (one per machine, child of the cmux Remote host)
  engine: call_id dedup -> policy -> takeover pause -> cursor -> desktop -> frames
  desktop: macOS (AX + window-scoped events) | Windows (UIA + window messages) | Linux (X11, Wayland, headless)
```

| Piece | Where | What it does |
| --- | --- | --- |
| Engine | `cmux-tui/crates/cmux-computer-use` (`engine.rs`, `tools.rs`, `policy.rs`, `session.rs`, `frame.rs`, `cursor.rs`, `keys.rs`) | One tool catalog, one policy decision function, sessions and saved approvals, frame redaction, downscale, change detection and PNG encoding. Platform-agnostic. |
| Desktops | `cmux-computer-use/src/desktop.rs` (the `Desktop` trait) and `src/platform/{macos,windows,linux}` | The platform seam. Every input is window-scoped and background-first; a route that cannot prove its target refuses. |
| C ABI | `cmux-tui/crates/cmux-computer-use-ffi` (`include/cmux_computer_use.h`) | The engine and the agent socket server for the Swift worker on macOS (`cmux_cu_*`). |
| Worker | macOS: `cmux-remote worker computer-use` in the signed cmux Remote.app. Linux and Windows: the `cmux-tui` binary's hidden `computer-use-worker` mode, supervised by the daemon. | Hosts the engine. One long-lived process per machine, so the OS grants (macOS Accessibility and Screen Recording) belong to one identity. |
| Agent socket | `cmux_computer_use::server` (Rust on every platform) | Speaks `cmux_computer_use::wire` (`cmux-computer-use-v1`). Admission: same uid (`getpeereid` or the pipe owner), then the per-launch secret. |
| Bridge | acpmux | Attaches the MCP server `cmux-computer-use` (and the `cu_*` tools in the folded `cmux` server) to every agent session cmux starts. Finds the worker by asking the cmux-tui daemon (`computer-use-endpoint`); it never reads endpoint files. Reconnects and retries a call with the same `call_id`. |
| Settings | `computerUse.*` in cmux.json, Settings → Computer Use, the palette, `cmux settings`, MCP `settings_*` | Mode, deny list, own machines, pause on takeover, foreground input, cursor. Agents are refused every `computerUse.*` key. |
| Remote | the receiving machine's daemon | A call with `machine` goes to that machine's worker. The receiving daemon sets the origin (`remote`, machine name, same account) from its authenticated peer, never from the request. |

### Control channel

The host talks to its worker over stdin and stdout, one JSON object per line:
`configure` (policy config, socket path, secret, state dir, machine name) is
answered by `ready`; later `config` and `approvals` (`forget`, `always`, `never`,
`revoke_sessions`) update it. On Linux and Windows the worker sends `ask` to the
host, which routes it to an attached cmux client and answers `allow_once`,
`allow_session`, `always`, `deny`, `never` or `unavailable`.

## Policy

One decision function (`policy::decide`) runs for every route: a local agent, the
CLI and a remote machine. The target app is resolved from the desktop, never from
the agent's words.

| Mode (`computerUse.mode`) | Effect |
| --- | --- |
| `off` | Every call is refused. |
| `lookOnly` | Discovery and observation only; actions are refused. |
| `askEveryTime` | The person is asked before an agent acts in an app. |
| `approvedApps` | Approved apps run at once; others ask once. |
| `fullAccess` (default) | Every app that is not denied. |

- `computerUse.deniedApps` (exact id, `prefix*`, `name:App Name`) holds password
  managers and keychains, System Settings, terminals and cmux by default; the
  person can remove any entry. The visible part of every denied window is
  painted out of display screenshots (an allowed window in front of it keeps
  its pixels, less a 12-point margin for rounded corners and shadows), so a
  whole-screen capture never shows a denied window. A translucent allowed
  window in front of a denied one shows it blurred, as it does on screen.
- Protected targets are never usable and not on the list: OS sign-in and
  authentication prompts (SecurityAgent, loginwindow, UAC consent, the polkit
  agents) and cmux Remote itself.
- `computerUse.allowOwnMachines` (default on): the person's other machines, on the
  same account, use this one without prompts when it is in Full access. Another
  account's machine is always refused.
- Cloud VMs are unrestricted: on a Linux machine with the root-owned Cloud image
  stamp `/etc/cmux/image-stamp`, every key the person's settings leave out takes
  `PolicyConfig::cloud_vm()` (Full access, no deny list, foreground input). A
  machine owner can also pin a policy in the root/SYSTEM-owned
  `/etc/cmux/computer-use.json` or `%ProgramData%\cmux\computer-use.json`, which
  wins over cmux.json.
- `computerUse.pauseOnTakeover` (default on): an acting call waits while the
  person uses the mouse or keyboard, and fails with `person_in_control` if they
  keep on.
- `computerUse.allowForeground` (default off; on for cloud VMs): whether
  `delivery: "foreground"` may raise a window and use system-wide input.

Grants, saved approvals and every acting call (recorded before it acts and again
with its result) live in the worker's state dir, so a worker restart keeps them
and a retried call never acts twice.

## Trust

The policy keeps agents from using apps the person did not mean them to use
through the Computer Use tools. It is not a sandbox against code that already
runs as the person: an agent with a shell can edit the person's cmux.json or the
worker's saved approvals, the same way it could edit any of the person's files.
Changes that widen access through Computer Use itself (Always allow, forgetting a
Never, a looser mode) need the cmux app or the person's own settings; that is
hardening, not a boundary. To hold an agent to less, run it as another user, in
a VM, or on a machine whose owner file pins the policy.

## Platforms and display servers

| Platform | Display server | Tree | Input | Capture | Notes |
| --- | --- | --- | --- | --- | --- |
| macOS 14+ | Quartz | Accessibility (AX) | AX actions, then events posted to the target process | ScreenCaptureKit, per window (covered windows too) | Needs Accessibility and Screen Recording for cmux Remote. |
| Windows 10/11 | Win32 | UI Automation | UIA patterns, then window messages to the target window | per window, per-monitor DPI aware | Elevated (UAC) windows are out of reach of a non-elevated worker and are refused. |
| Linux | X11 | AT-SPI | AT-SPI actions, then XTEST scoped to the window | Composite, per window | The reference Linux path. |
| Linux | Xvfb / headless X | AT-SPI | as X11 | as X11 | Cloud VMs and CI. |
| Linux | Wayland | AT-SPI | portals (RemoteDesktop) or wlroots protocols where the compositor allows | ScreenCast portal or wlroots screencopy | What works depends on the compositor; `status` reports it. A target that cannot be proven is refused. |

## Licensing

- `cmux-computer-use` and `cmux-computer-use-ffi` are MIT (Copyright (c) 2026
  Manaflow, Inc.), so Computer Use can ship as its own component on every
  platform. The Swift worker files in the app keep the repo's
  `GPL-3.0-or-later` header.
- No cua or cua-driver code was copied. trycua/cua (MIT) was read as a reference
  only.
- cua-driver-rs v0.38.0 (trycua/cua tag `cua-driver-rs-v0.38.0`, commit
  `85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19`, MIT) is pinned only as the eval
  baseline ([evals.md](evals.md)); it is downloaded by the eval harness and never
  shipped. The cua-driver-bench task pack is FSL-1.1 and is never copied; our
  eval tasks are our own.
- `Packages/Shared/CmuxAgentCursor` was taken from manaflow-ai/cmux-cua under MIT
  and keeps that notice (THIRD_PARTY_LICENSES.md, "Agent cursor").

## Lessons from cua-driver

What we kept:

- Window-scoped background input: every action names its window, never
  activates the app and never moves the person's pointer.
- Refuse rather than guess: a target that cannot be resolved is refused before
  any input is sent.
- Structured evidence: results say what happened, from the target window, with
  stable refusal codes an agent can act on.

What we changed:

- The tools are listed without the worker. acpmux serves the catalog itself, so
  `tools/list` works while the worker starts or restarts; a call waits for it.
- `call_id` dedup across restarts. A bridge that retries after a reconnect never
  runs an acting call twice.
- Grants persist in the worker's state dir instead of dying with the process.
- One policy chokepoint for local agents, the CLI and remote machines, with the
  origin set by the receiving daemon.
- Denied windows are redacted out of display screenshots, not only refused as
  targets.
- No per-spawn driver selection: one engine per machine, no `computerUse.driver`
  switch, nothing an agent can pick.

## Older pages

[docs/computer-use.md](../computer-use.md) described the retired `cmux-cua`
helper and now points here.
