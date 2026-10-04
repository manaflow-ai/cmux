# Ghostty config fidelity: settings hierarchy (R92 proposal)

Status: proposal to the coordinator, 2026-10-04. Inventory: [ghostty-config-inventory.md](ghostty-config-inventory.md).

## Principles

1. One owner per setting. Ghostty's schema (`Config.zig`) owns every key it defines. cmux.json never
   has its own key for a value Ghostty defines; cmux-only concepts (sidebar, columns, Liquid Glass
   chrome, divider opacity, leader key) stay in cmux.json.
2. One parser and one resolver: libghostty's `Config` (Zig). No Rust or Swift code parses Ghostty
   syntax. The two Rust parsers (`cmux-tui/src/config.rs` Ghostty section, `cmux-theme-tokens/src/config.rs`) are deleted.
3. Every key is classified in code (`GhosttyKeySupport`: applied / applied-by-cmux / host / decide-superseded / n/a with a
   reason). A test enumerates the keys of the linked libghostty at run time and fails when a key has
   no classification, so a ghostty-next bump cannot add an unhandled key silently.

## Layers (later wins), all loaded into one libghostty Config

| # | layer | written by | example |
| --- | --- | --- | --- |
| 1 | Ghostty built-in defaults | ghostty-next | `scrollback-limit-bytes = 50000000` |
| 2 | cmux defaults (source tag `cmux-next`) | cmux source | padding, `theme = light:Apple System Colors Light,dark:Apple System Colors`, `super+j=unbind` |
| 3 | user Ghostty files: `config`, `config.ghostty` (XDG then App Support) + `config-file` includes | user | `~/.config/ghostty/config` |
| 4 | cmux.json `ghostty` object (source tag `cmux.json`) | Settings page or user | `"ghostty": {"font-size": "14", "keybind": ["cmd+d=new_split:right"]}` |
| 5 | scoped cmux layers: workspace, room or terminal theme | cmux UI | `theme` only |
| 6 | runtime per-surface state | gestures | font zoom |

Layer 4 is the cmux-only Ghostty layer: Ghostty key names, Ghostty value strings (repeatable keys as
arrays), parsed by libghostty with `ghostty_config_load_string`. It lets a user configure cmux
differently from Ghostty.app without a second schema. Migration (once, on load): `appearance.theme`
-> `ghostty.theme`; `terminal.fontFamily` -> `ghostty.font-family` (appended, so the fallback list
is kept; fixes bug 2); `terminal.fontSize` -> `ghostty.font-size` (no rounding; bug 3);
`appearance.backgroundOpacity` -> `ghostty.background-opacity`; `appearance.backgroundBlur`
(`frosted|glass|glass-clear|none`) -> `ghostty.background-blur` (`true|macos-glass-regular|macos-glass-clear|false`);
`appearance.surfaces.splitDivider.color` -> `ghostty.split-divider-color`. R93 decisions:
`unfocused-split-opacity` and `unfocused-split-fill` own the inactive-pane dim (the 0.14 Debug
tunable becomes the cmux default in layer 2, overridable by the user); `split-divider-color` owns the
divider color; `appearance.surfaces.splitDivider.opacity` stays cmux-only (Ghostty colors have no alpha).

## The session host gets the same resolved config

The viewer drops every reply in MANUAL_MIRROR, so reply and spawn keys are host keys. The Mac app
resolves them with the same Config and sends a typed `TerminalProfile` (scrollback bytes and lines,
grapheme width, fg/bg/cursor/palette for light and dark, cursor style and blink,
osc-color-report-format, enquiry-response, title-report, clipboard-read policy,
vt-window-resize-allowed) with op `terminal-profile.set {owner: install id, generation}`, at connect
and after each reload. `create-terminal` carries the spawn spec resolved at create (command,
initial-command, env, input, working-directory and the inherit rules, term with TERMINFO,
shell-integration env and args, wait-after-command, abnormal-command-exit-runtime) and the owner's
profile reference. The host applies the profile through libghostty-vt options (`SCROLLBACK_MAX_LINES`,
`ENQUIRY`, `TITLE_REPORT`, `CLIPBOARD_READ`, `COLOR_SCHEME`, `SIZE`, `TERMINFO_NAME`, default
colors) and never injects shell integration itself when the spec says the client resolved it (bug 5).
Owner rule: a terminal follows its creator's profile; a creator's reload updates its terminals.
`clipboard-read = ask` forwards the read to the creator client, which asks; no client attached =
deny. Terminals created with no client (standalone cmux-tui, CLI on a VM) use the host machine's
profile, resolved by the bundled `ghostty +show-config` helper (Ghostty's own resolver) off the
startup path, cached by file mtimes, with Ghostty plus cmux defaults until it returns. A restored
snapshot never sets colors or cursor defaults; the profile wins (S2b fixes the restore path).

## Settings page, reload, diagnostics

- Settings > Terminal lists Ghostty keys by group with the effective value and its source: Ghostty
  default, cmux default, `<file>:<line>`, or cmux.json. Editing writes layer 4 (cmux.json `ghostty`);
  "Reset" removes the layer-4 entry; "Open in Ghostty config" opens the real file at the line. cmux
  never writes the user's Ghostty files (hand-written, shared with Ghostty.app, includes and
  comments). Values are validated by loading them into a scratch Config and reading diagnostics
  before the write. Needs three ghostty-next fork APIs (header has none today): key enumeration (for the
  classification test), per-key source location, and the loaded-file list.
- Live reload: a vnode watch (DispatchSource) on every loaded file and its directory (atomic saves,
  new files), coalesced into one reload per burst; no polling. The reload pushes a new profile
  generation to each host. A failed parse keeps the last good config and reports.
- Diagnostics, one model, one action path (palette, CLI `cmux ghostty-config --json`, MCP tool,
  Settings section, `cmux doctor`): libghostty diagnostics with file:line, keys set but not
  applicable in cmux (with the reason from `GhosttyKeySupport`), layer 4 or 5 overriding a file
  value, keybind collisions, profile push failures. Remove the template-file side effect (bug 10)
  and the hard-coded config path (bug 9; use `ghostty_config_open_path`).

## Keybinds

cmux.json `shortcuts` (explicit user) > user Ghostty `keybind` lines (layers 3 and 4, focused
terminal) > cmux default shortcuts > Ghostty default keybinds. This extends K-T1 to every chord.
Every Ghostty apprt action routes to the cmux action catalog (fill the 22 undecoded and 7 nil
routes); `global:` keybinds register a system hotkey.

## Decisions for Lawrence (via the coordinator)

1. The 22 `decide` keys where cmux has its own concept (titlebar style, window buttons, window
   decoration, quick terminal, new-tab position, ...): apply them, or report them as superseded
   in diagnostics. Proposal: apply `window-width/height/position`, `maximize`, `fullscreen`,
   `window-save-state`, `confirm-close-surface`, `quit-after-last-window-closed`, bell and notify
   keys now (they are in the `fix` list); report titlebar/decoration keys as superseded by
   `window.titlebar`; build the quick terminal as its own slice.
2. Keybind order above: a user's Ghostty `super+j` line would beat the cmux Cmd-J leader in
   terminals.
3. Layer 4 in cmux.json versus a separate Ghostty-syntax file `~/.config/cmux/ghostty`.

## Strongest objection and trade-offs

Objection: Ghostty's config is Ghostty.app's, not an API, and the session host is shared. Applying
app and window keys makes cmux a Ghostty skin coupled to another product's schema, and one grid
cannot honor two clients' different reply keys. Answers: terminal-surface keys always apply;
app/window keys apply only where cmux has the same concept, others are reported; layer 4 lets cmux
differ from Ghostty.app; the pinned fork plus the classification test catch schema changes; host
keys follow the creator, which is deterministic and documented (a second client sees its own
rendering, input and keybinds, but the creator's replies). Trade-offs: three small fork APIs to carry;
cmux.json keys migrate (one-time, logged); `+show-config` adds a process spawn for client-less
hosts (off the startup path); clipboard-read prompts need a client round trip.
