# Remote Desktop (`cmux/remote-desktop`)

View and control the desktop of your Macs, cmux servers and team VMs in a cmux pane. Plan: `plans/cmux-next/remote-desktop.md` (section 10 for this app, 11 for security).

Status: development only (`x-cmux-devOnly`). The package is manifest v2 only (`cmux-app.v2.json`), so it is not bundled or listed in the App Store; `cargo test -p cmux-app-manifest` validates it with the other first-party apps.

## Parts

| Part | Where | What |
| --- | --- | --- |
| native server | `cmux-rd host` (`cmux-tui/crates/cmux-rd-host`, GPL-3.0-or-later), one per machine | serves the `rd.*` ops and the media stream; binds loopback by default and needs the per-launch `--token-fd` token (plan 11.0) |
| native pane `remote-view` | `Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView`, in the app process | the `remote_view` tab: decode, present, input capture |
| tab record | workspace store, browser tab record `cmux://remote-view?host=<host>&target=<target>&mode=<mode>` | which desktop a tab shows (host, target, mode), never the stream; persisted and restored like `cmux://history`; records from a remote machine's tree never open it |

`target` is `display:<n>`, `window:<id>` or `virtual`; `mode` is `view` or `control` (default `view` in the record). In Release and NIGHTLY builds the tab shows "Remote desktop is not available". In development builds the host `mock` shows a VideoToolbox test desktop; other hosts wait for the in-app transport (cmux-rd-core in the client).

## Catalog (`catalog/rd-catalog.json`, family `rd`)

| Op | Risk | MCP | CLI | Notes |
| --- | --- | --- | --- | --- |
| `rd.view.open` | mutate-own | default | `rd open` | view-only tab for the person; never focuses; the agent path (plan: MCP `remote_desktop_open`); in phase 1 the tab streams only after the person presses Connect |
| `rd.session.start` | execute | never | `rd connect` | gesture required (no actor stamp yet, plan 11.0); control is code execution on the host; host owner or granted principals only, never agents; palette "Connect to Desktop…" |
| `rd.session.stop` | mutate-own | default | `rd stop` | a viewer stops only its own sessions |
| `rd.session.list` | read | default | `rd ls` | |
| `rd.control.request` | execute | never | `rd control request` | gesture required |
| `rd.control.release` | mutate-own | never | `rd control release` | always allowed |
| `rd.host.enable` | mutate-own | never | `rd host enable` | a person on that machine; gesture required |
| `rd.host.disable` | mutate-own | never | `rd host disable` | any local caller (it only removes access) |
| `rd.host.grant` | execute | never | `rd host grant` | a control grant lets another principal type here; a person on that machine after re-authentication; gesture required |
| `rd.host.revoke` | mutate-own | never | `rd host revoke` | a person on that machine; gesture required |
| `rd.host.stop_all` | mutate-own | never | `rd host stop-all` | ends every session; any local caller (it only removes access) |
| `rd.audit.list` | read | default | `rd audit` | never screen content |
| `rd.bench` | read | never | `rd bench` | development builds |

Every op has `remote_relay: deny` and `queue_offline: false`. No op takes a command, path or URL parameter; `host`, `target`, `session`, `principal` and `grant` are pattern-checked ids (plan 11.1). The idempotency key rides the `apps-run` envelope (app-platform.md 12), not the op input.

The plan's single `rd.session.start` with "execute (control) or read (view)" risk is split in two: a catalog op has one risk, so `rd.view.open` is the view-only path agents may use and `rd.session.start` stays people only.

## Gaps

- No op is served yet: the daemon does not supervise `cmux-rd` or route `rd.*` (app platform APP-R1), and the host engine speaks `cmux.rd/1` only.
- The macOS host (phase 2) runs inside the screen agent helper; `server.binaries` cannot name a helper bundle, so only the Linux binaries are listed.
- `sidebarSections` (Desktops) and `paletteScopes` (plan 10) are not declared; a JS section prototype from an earlier draft is archived outside the repo.
