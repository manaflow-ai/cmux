# Native Frontend Ownership

This document owns cmux-tui behavior that belongs to one interactive frontend
rather than the shared mux. It prevents local UI state, host terminal side
channels, and filesystem access from being mistaken for portable control
protocol features.

## Entrypoints

The configurable `Action` and context-menu `MenuAction` enums are exhaustively
classified in [`inventory.json`](inventory.json). CI rejects an added variant
without a route. Actions may call a mux command, compose snapshot or geometry
state with a command, invoke the separate machine-provider protocol, or remain
frontend-only.

Direct pointer routing, omnibar hits, drag state, selection, and file-sidebar
navigation do not all have enum variants. They remain frontend-owned unless a
shared command in [`commands.md`](commands.md) explicitly takes authority.
Remote automation of frontend-owned behavior uses the proposed adapter in
[`programmability.md`](programmability.md#frontend-action-adapter).

## Startup workspace mutation

The native TUI prepares visible topology before entering terminal mode. When
machine-provider state does not suppress initialization, a local in-process
session calls `new-workspace` on every native startup, even when restored
workspaces already exist. An attached remote session instead refreshes the
tree and calls `new-workspace` only when the session has no workspaces.

The initial cell size is the first pane's computed content rectangle after
sidebar and border layout; unavailable terminal geometry falls back to normal
mux sizing. A spawn failure aborts startup before terminal mode.

Machine-provider state can suppress this mutation. The native TUI creates
nothing when the selected machine session is unavailable or its workspace
creation policy is provider-owned. For other available machine sessions, the
local-versus-remote rules above apply. A replacement frontend that intends to
match native startup must reproduce this decision before rendering; merely
connecting is not read-only under the local native path.

## Configuration

The current key and default contract is [`docs/configuration.md`](../docs/configuration.md).
Resolution is `CMUX_TUI_CONFIG`, legacy `CMUX_MUX_CONFIG`, then
`$XDG_CONFIG_HOME/cmux/cmux-tui.json` or `~/.config/cmux/cmux-tui.json`, with
legacy `mux.json` only when the preferred file is absent.

Typed sections reject unknown fields. A parse failure logs an error and loads
defaults rather than partially applying the document. The built-in sidebar
default is `workspaces`. `theme.chrome` accepts `auto`, `light`, or `dark`.
`reload-config` requests a frontend reload; it is not a transactional config
write and does not prove every runtime resource was restarted.

Current keymap grammar, default bindings, replacement rules, and prefix
behavior are local configuration. A portable config API requires the
versioned schema, ownership, validation, patch, and change-event contract in
`programmability.md`.

## Host terminal side channels

The native TUI may:

- query OSC 10 and OSC 11 briefly at startup and use the replies as color
  defaults;
- write OSC 52 to copy a local selection;
- write OSC 22 pointer-shape updates over clickable UI;
- use Kitty graphics and keyboard capabilities;
- probe terminal pixel geometry and fall back to an implementation default.

These are capabilities of the outer terminal, not mux state. They have no
delivery acknowledgement in protocol v9. A remote render client must negotiate
and implement its own host capabilities; it must not infer support from
`identify.protocol`.

Selection coordinates, hover, pressed pointer targets, omnibar text, menus,
sidebar focus, rail widths, and a remote frontend's scroll position are
frontend-local. The mux exposes terminal text and shared topology, not those
ephemeral interaction states.

## Filesystem and process launch

The built-in file sidebar reads the TUI host filesystem directly and may open a
file through `$EDITOR`, change a terminal directory, or create a browser file
URL. It is available only when the frontend can access the same filesystem.
A browser or remote frontend needs the separately permissioned filesystem
capability proposed in `programmability.md`; mux control authority alone does
not grant file access.

## Localization

The native catalog currently contains English and Japanese strings for
pairing, foreign viewport hints, and machine/sidebar flows. Locale precedence
is `LC_ALL`, then `LC_MESSAGES`, then `LANG`; values beginning with `ja`
select Japanese and every other value selects English.

The catalog does not yet cover every native label. Frontend SDKs receive
semantic state and error codes where available; they do not receive prelocalized
UI prose. Portable frontend localization requires stable message keys and
catalog completeness checks.

## Diagnostics and sensitive data

Status events are transient presentation messages. Subprocess diagnostics have
component-specific byte bounds and redaction, so they are not a stable logging
API.

`CMUX_MUX_DEBUG_MIRROR_DUMP` is a local diagnostic switch. When set, a remote
TUI retains frame logs and writes terminal mirror contents on drop to the named
directory. Those files can contain terminal secrets. Tooling must treat the
directory as sensitive, opt-in storage and must not enable it for ordinary
sessions.
