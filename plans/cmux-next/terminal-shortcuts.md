# Terminal shortcuts: shipping cmux, Ghostty and cmux-next

Status: audit and fixes 2026-10-11 (bd cx-442, K1). Rule: cmux-next matches the shipping cmux
(manaflow-ai/cmux `main`, `Sources/`) where it has the shortcut, else Ghostty's macOS default.
The user's Ghostty config wins over both (docs/ghostty-keybindings.md "Precedence and focus").
A cmux feature that a Ghostty `keybind` line already gives is not added.

Sources read: shipping cmux `main` 46c8146e (`KeyboardShortcutSettings.swift`,
`AppDelegate.swift`, `GhosttyTerminalView.swift`, `GhosttyApp+KeybindOverrides.swift`);
Ghostty `src/config/Config.zig` `Keybinds.init` at the submodule commit 7e880f6 (the older
ghostty-next and ghostty-sync checkouts have the same macOS defaults); cmux-next
`feat-cmux-next` b6e4b1d4d66a (the action catalogs, `KeyBindingDefaults`, `KeyRouter`,
`TerminalKeyEquivalent`, `GhosttyRuntime+Keybinds`, `TerminalHostActionRoute`).

How a key reaches a cmux-next terminal: the key router decides Cmd and Ctrl chords against
the binding table (user cmux.json > user Ghostty keybinds > cmux defaults > Ghostty
defaults); a key it does not run goes to the terminal view, where Ghostty's own keybinds
(with `performable:` and `unconsumed:`) act and every other key is encoded for the program.
Keys without Cmd or Ctrl (Option-arrows, Shift-arrows, Shift-Return) never reach the table.

Legend: "Ghostty" = the key reaches the terminal and Ghostty's keybind acts. "program" = the
terminal program gets the encoded key. FIXED = changed by this audit.

## Clipboard and selection

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Copy | Cmd-C (Edit > Copy, the user's Ghostty copy action; nothing selected on the alternate screen: Cmd-C goes to the program) | Cmd-C `performable:copy_to_clipboard` (nothing selected: the program gets Cmd-C) | Cmd-C `terminalCopy`. Before: with nothing selected it refused and ate the key, and a disabled Edit > Copy also ate it | FIXED: with nothing selected Cmd-C goes to the program through Ghostty on any screen, as in Ghostty (legacy encoding sends nothing for a Command key, so only Kitty-protocol TUIs see it) |
| Paste | Cmd-V | Cmd-V `performable:paste_from_clipboard` | Cmd-V `terminalPaste` | match |
| Paste selection | Cmd-Shift-V (Ghostty) | Cmd-Shift-V `paste_from_selection` | Ghostty | match |
| Select all | Cmd-A (Ghostty) | Cmd-A `select_all` | Edit > Select All -> Ghostty `select_all` | match |
| Extend selection | Shift-arrows, Shift-PageUp/Down/Home/End (Ghostty) | `adjust_selection` | Ghostty | match |
| Copy mode | Cmd-Shift-M | none | Cmd-Shift-M `toggleTerminalCopyMode` | match |

## Clear and font size

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Clear screen and scrollback | Cmd-K (Ghostty `clear_screen`) | Cmd-K `performable:clear_screen` | Cmd-K `terminal.clear` (daemon clear-history, 8251d62d6a8e, 4b5d8e0886f5) | match |
| Clear screen, keep scrollback | Cmd-Shift-K | none | Cmd-Shift-K `clearScreenKeepScrollback` | match |
| Font size, this terminal | Cmd-= / Cmd-+ / Cmd-- / Cmd-0 (Ghostty) | `increase_font_size:1`, `decrease_font_size:1`, `reset_font_size` | `terminal.increaseFontSize` etc. run the same Ghostty actions; the workspace-wide actions on the same keys yield in a terminal | match |
| Font size, whole workspace | Ctrl-Cmd-= / Ctrl-Cmd-- / Ctrl-Cmd-0 | none | Cmd-= / Cmd-- / Cmd-0 outside a terminal; Ctrl-Shift-Cmd-=/-/0 is UI scale (Ctrl-Cmd-= is Equalize) | differs by an earlier cmux-next decision (UI scale); see Decisions |

## Splits and panes

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Split right / down | Cmd-D / Cmd-Shift-D | `new_split:right` / `new_split:down` | Cmd-D `splitRight` / Cmd-Shift-D `splitDown` | match |
| Focus pane in a direction | Cmd-Opt-arrows | Cmd-Opt-arrows `goto_split` | Cmd-Opt-arrows `focusLeft` etc. (also Ctrl-Cmd-H/J/K/L). 2f3e1f95983 had moved Cmd-Opt-Left / Right to the sidebar; back to pane focus 2026-10-20 and reserved (schemas/keybindings/ghostty-reserved-keys.json) | match |
| Focus previous / next pane, focus history | Cmd-[ / Cmd-] focus history Back / Forward (no pane previous / next key) | Cmd-[ / Cmd-] `goto_split:previous/next` | Cmd-[ / Cmd-] `focusHistoryBack` / `focusHistoryForward` everywhere but a web page (Back / Forward there), also Ctrl-- / Ctrl-Shift-- outside a terminal. Before: the key router consumed Cmd-[ / Cmd-] outside a browser, so they did nothing in a terminal | FIXED (chief decision): matches the shipping cmux; a `super+[` / `super+]` keybind in the user's Ghostty config still wins |
| Focus pane N | Ctrl-Cmd-1...9 | none | Ctrl-Cmd-1...9 `focusPaneByNumber` | match |
| Resize pane | Ctrl-Shift-H/J/K/L; Ctrl-Cmd-arrows (Ghostty) | Ctrl-Cmd-arrows `resize_split` | both, `resizePane*` | match |
| Zoom pane | Cmd-Shift-Return | Cmd-Shift-Return `toggle_split_zoom` | Cmd-Shift-Return `toggleSplitZoom` | match |
| Equalize | Ctrl-Shift-Cmd-= | Ctrl-Cmd-= `equalize_splits` | Ctrl-Cmd-= `equalizeSplits` (Lawrence 2026-10-19; UI scale moved to Ctrl-Shift-Cmd-=/-/0) | matches Ghostty, differs from the shipping cmux |
| New pane, auto layout | Ctrl-Cmd-N | none | Ctrl-Cmd-N `newPaneAutoLayout` | match |

## Tabs, workspaces and windows

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| New tab | Cmd-T | Cmd-T `new_tab` | Cmd-T `newTab.default` | match |
| Close tab | Cmd-W | Cmd-W `close_surface` | Cmd-W `closeTab` | match |
| Close other tabs in pane | Cmd-Opt-T | none | Cmd-Opt-T `closeOtherTabsInPane` | match |
| Cmd-Opt-W | nothing (Ghostty `close_tab:this` unbound) | `close_tab:this` | Before: Ghostty `close_tab:this` closed the tab | FIXED: unbound in cmux's Ghostty defaults; the key goes to the program |
| Cmd-Opt-Shift-W | nothing (Ghostty `close_all_windows` unbound) | `close_all_windows` | Before: Ghostty closed every window | FIXED: unbound in cmux's Ghostty defaults |
| Next / previous tab | Cmd-Shift-] / [; Ctrl-Tab / Ctrl-Shift-Tab | Cmd-Shift-] / [, Ctrl-Tab / Ctrl-Shift-Tab `next_tab` / `previous_tab` | Cmd-Shift-] / [ and Ctrl-Tab / Ctrl-Shift-Tab: the focused pane's next / previous tab (`nextSurface` / `prevSurface`, Lawrence 2026-10-15, #20116); Ctrl-Cmd-] / [: next / previous sidebar item (`nextSidebarTab` / `prevSidebarTab`); Ghostty's `next_tab` / `previous_tab` run the same pane-tab actions; Ctrl-PageDown / Up have no cmux default; the user's Ghostty keybinds win over all of these (Lawrence 2026-10-20) | match for Cmd-Shift-] / [ and Ctrl-Tab |
| Tab N | Ctrl-1...9 (9 = last) | none | Ctrl-1...9 `selectSurfaceByNumber` | match |
| Workspace N | Cmd-1...9 | Cmd-1...8 `goto_tab`, Cmd-9 `last_tab` | Cmd-1...9 `selectWorkspaceByNumber` | match |
| Move tab | Cmd-Opt-Shift-[ / ]; Cmd-Opt-Shift-arrows; Ctrl-Shift-Cmd-[ / ] | none on macOS | the same keys, `moveSurface*` | match |
| Next / previous workspace | Ctrl-Cmd-] / [ | none | Ctrl-Cmd-] / [ `nextSidebarTab` / `prevSidebarTab` | match |
| New workspace / window | Cmd-N / Cmd-Shift-N | Cmd-N `new_window` | Cmd-N `newTab` / Cmd-Shift-N `newWindow` | match |
| Close workspace | Cmd-Shift-W | Cmd-Shift-W `close_window` | Cmd-Shift-W `closeWorkspace` | match |
| Rename tab / workspace | Cmd-R / Cmd-Shift-R | none | Cmd-R `renameTab` / Cmd-Shift-R `renameWorkspace` | match |
| Reopen closed | Cmd-Shift-T | Cmd-Shift-T `undo` | Cmd-Shift-T `reopenClosedBrowserPanel` | match |
| Full screen | Ctrl-Cmd-F (Ghostty Cmd-Return unbound) | Cmd-Return and Ctrl-Cmd-F `toggle_fullscreen` | Ctrl-Cmd-F `toggleFullScreen`. Before: Cmd-Return in a terminal toggled full screen (Ghostty) and the checklist default had Cmd-Return everywhere | FIXED: Ghostty `super+enter` unbound in cmux's defaults and `toggleChecklistItemComplete` yields in a terminal, so Cmd-Return reaches the program |
| Command palette | Cmd-Shift-P | Cmd-Shift-P `toggle_command_palette` | Cmd-Shift-P `commandPalette` | match |
| Settings / reload config | Cmd-, / Cmd-Shift-, | `open_config` / `reload_config` | Cmd-, `openSettings` / Cmd-Shift-, `reloadConfiguration` | match |
| Quit | Cmd-Q | Cmd-Q `quit` | Cmd-Q `quit` | match |

## Scrollback, prompts and line editing

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Previous / next prompt | Cmd-Up / Cmd-Down (Ghostty) | Cmd-Up / Cmd-Down and Cmd-Shift-Up / Down `jump_to_prompt` | Ghostty | match |
| Previous / next agent turn | Cmd-Shift-Up / Down when the agent-turn rail shows | none | Ghostty `jump_to_prompt` (cmux-next has no terminal agent-turn rail) | match while there is no rail |
| Scroll to top / bottom | Cmd-Home / Cmd-End (Ghostty) | `scroll_to_top` / `scroll_to_bottom` | Ghostty | match |
| Page up / down | Cmd-PageUp / Cmd-PageDown (Ghostty) | `scroll_page_up` / `scroll_page_down` | Ghostty | match |
| Scroll to selection | none (Cmd-J is Click by Hint) | Cmd-J `scroll_to_selection` | Cmd-J J `terminal.scrollToSelection` (Cmd-J is the leader; `super+j` unbound) | differs by an earlier cmux-next decision (leader key) |
| Line start / end | Cmd-Left / Cmd-Right (Ghostty) | `text:\x01` / `text:\x05` | Ghostty | match |
| Delete to line start | Cmd-Backspace (Ghostty) | `text:\x15` | Ghostty | match |
| Word left / right | Opt-Left / Opt-Right (Ghostty) | `esc:b` / `esc:f` | Ghostty | match |
| Text editing gestures (Cmd-Delete, Opt-Backspace, Ctrl-arrows) | opt-in setting `terminal.textEditingGestures`, off by default | none | none | not ported: a Ghostty `keybind` line (`super+delete=text:\x0b`, `alt+backspace=text:\x17`) gives each one |
| Option as Meta | Ghostty `macos-option-as-alt` (unset: Alt on U.S. layouts, dead keys elsewhere) | same | Ghostty `macos-option-as-alt` through `ghostty_surface_key_translation_mods` | match; no cmux setting (Ghostty config provides it) |
| Ctrl-/ and Ctrl-Return | Ctrl-/ sent as Ctrl-_; Ctrl-Return to the terminal | none | the same (`TerminalKeyEquivalent`) | match |
| Undo / redo | Cmd-Z / Cmd-Shift-Z go to the program (Ghostty undo unsupported) | Cmd-Z `performable:undo`, Cmd-Shift-Z `performable:redo` | Ghostty `undo` routes to `history.reopen` (reopens the last closed item when there is one); redo unrouted | differs by an earlier cmux-next decision; see Decisions |

## Find

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Find | Cmd-F (cmux find bar over Ghostty search) | Cmd-F `start_search` | Cmd-F `find` | match |
| Find next | Cmd-G | Cmd-G `navigate_search:next` | Cmd-G `findNext` | match |
| Find previous | Cmd-Opt-G (Cmd-Shift-G was Group Workspaces) | Cmd-Shift-G `navigate_search:previous` | Cmd-Opt-G `findPrevious`; Cmd-Shift-G in a terminal is Ghostty's (decision K1 follow-up) | match |
| Use selection for find | Cmd-E | Cmd-E `search_selection` | Cmd-E `useSelectionForFind` | match |
| Hide find | Cmd-Opt-Shift-F; Escape | Escape `end_search` | Cmd-Opt-Shift-F `hideFind`; Escape in the find bar | match |
| Find in directory | Cmd-Shift-F | Cmd-Shift-F `end_search` | Cmd-Shift-F `findInDirectory` | match |

## Inspector and screen file

| Action | Shipping cmux | Ghostty default | cmux-next | State |
| --- | --- | --- | --- | --- |
| Terminal inspector | Cmd-Opt-I passes to Ghostty, which does nothing (unsupported) | Cmd-Opt-I `inspector:toggle` | Ghostty `inspector` unrouted (does nothing); Cmd-Opt-I is DevTools in a browser | match |
| Write screen to file | Ghostty | Cmd-Shift-J, Ctrl-Shift-Cmd-J, Cmd-Opt-Shift-J `write_screen_file` | Ghostty | match |

## Fixes in this landing

1. `GhosttyRuntime.cmuxDefaultKeybindLines` unbinds `super+enter`, `super+alt+w` and
   `super+alt+shift+w` before the user's files load, as the shipping cmux does
   (`GhosttyApp+KeybindOverrides.swift`). A user's own `keybind` line for one of those keys
   still wins. Of the three, only Cmd-Opt-Shift-W (`close_all_windows`) was a Ghostty
   fallback entry of the binding table, so Close All Windows has no default shortcut now,
   as in the shipping cmux.
2. `toggleChecklistItemComplete` (Cmd-Return) is in `KeyBindingDefaults.yieldsToTerminal`.
3. Copy with nothing selected (`TerminalSurfaceView.copy`) sends Cmd-C to Ghostty, whose
   `performable:` copy keybind passes it to the program; Edit > Copy stays enabled in a
   terminal so a disabled item no longer swallows the key (the shipping cmux keeps it enabled
   for the same reason). `terminalCopy` from a key does this; from a menu, the palette or the
   CLI it still refuses "nothing selected".

Proof: `scripts/cmux-next/terminal-keys-e2e.py` on a tagged app on cmux-lawrence-2
(`debug.key` through the key router, the window, the menu and the terminal view). It checks
the fixed keys (Cmd-Return, Cmd-Opt-W, Cmd-Opt-Shift-W, Cmd-C with and without a selection)
and prints an OWNER line for every other terminal key above. Run 1 (M1 Max, tag b442m1, at
01e144c8e4c7) confirmed Cmd-Return and both Cmd-Opt-W keys reach the program and found the
disabled Edit > Copy swallowing Cmd-C; fix 3 is the result. Run 2 (M1 Max, tag b442m1, at
c28a2f090454): every row of the fixed keys passes (Cmd-Return resolve outcome none and
handled by the responder with no Ghostty binding; Cmd-Opt-W and Cmd-Opt-Shift-W the same,
nothing closed; Cmd-C with nothing selected runs terminalCopy with no refusal; Cmd-C after
Cmd-A runs terminalCopy). The OWNER lines match the cmux-next column. The script's
first-terminal Cmd-K rows fail in both runs because that terminal is not first responder
(child bead of cx-442); the Cmd-K rows in the focused split pass.

4. Cmd-[ / Cmd-] (chief decision 2026-10-11): `KeyBindingDefaults.focusHistoryAliases` bind
   them to `focusHistoryBack` / `focusHistoryForward` with `when: surfaceKind != page && !codeEditorFocused`
   (the code editor keeps outdent / indent). They
   sit first in the default layer, so the browser's and the Markdown viewer's own Back /
   Forward on the same keys (later, more specific) win in those surfaces, a user Ghostty
   `super+[` keybind (Ghostty layer) wins everywhere, and a cmux.json override of the action
   removes them. Proof: terminal-keys-e2e.py rows "terminal Cmd-[" and "terminal Cmd-]".

## TUI agents (Claude Code, Codex, OpenCode), 2026-10-23

What the agents bind (read from Claude Code 2.1.309's keybinding table, OpenCode's keybind docs,
openai/codex#48122): Claude Code `cmd+c` selection:copy (fullscreen mode, its own selection) and
`cmd+k` clear screen, Ctrl-V image paste; Codex `super+c` copy of its own selection; OpenCode
`super+z` / `super+shift+z` undo / redo and `super+a` select all. A Command key reaches a program
only under the Kitty keyboard protocol (Claude Code pushes `CSI >5u` under `TERM_PROGRAM=ghostty`,
Codex and OpenCode push their flags); legacy encoding sends nothing for it on macOS.

| Key | Before | Now |
| --- | --- | --- |
| Cmd-C, nothing selected | Ghostty on the app's mirror encoded it (`performable:` copy) | the tab's daemon encodes `super+c` with the terminal's own keyboard modes (`send-key`, the shipping cmux's `sendNamedKey("super+c")`); the mirror path stays the fallback without a daemon terminal or when an older machine daemon refuses the key |
| Cmd-K | `terminal.clear`: daemon clear-history; an alternate-screen program got nothing | from a key, clear-history carries `super+k` as its fallback key: the primary screen clears as before, an alternate-screen Kitty program gets Cmd-K (Ghostty's `performable:clear_screen`); a legacy one gets nothing, silently |
| Cmd-Z / Cmd-Shift-Z | Edit > Undo / Redo (Reopen Last Closed) | when the program reads the mouse (`ghostty_surface_mouse_captured`: Claude Code fullscreen, OpenCode, Codex), `super+z` / `super+shift+z` to the program through the daemon; a shell keeps Edit |
| Cmd-A | Edit > Select All (Ghostty `select_all`) | the same rule: `super+a` to a program that reads the mouse |
| Cmd-V image | the image saved to a temp file and its path pasted | unchanged (Claude Code and Codex attach a pasted image path; Ctrl-V reaches the program as Ctrl-V) |
| Cmd-Backspace, Cmd-Left / Right | Ghostty `text:\x15`, `\x01`, `\x05` | unchanged (line editing every agent reads) |
| Option-arrows, Option-Backspace | Ghostty `esc:b` / `esc:f`; Alt-Backspace encoded | unchanged |
| Shift-Return | encoded by Ghostty (`CSI 13;2u` under Kitty) | unchanged |

`send-key` gained the `super` / `cmd` / `command` modifier (cmux-tui `ghostty_vt::key_input_from_chord`).

## Decisions (earlier cmux-next choices that differ from the shipping cmux; the chief kept them, 2026-10-11)

- Workspace-wide terminal font size: the shipping cmux uses Ctrl-Cmd-=/-/0; cmux-next uses
  Cmd-=/-/0 outside a terminal and gives Ctrl-Shift-Cmd-=/-/0 to UI scale (moved from Ctrl-Cmd
  on 2026-10-19, when Lawrence gave Ctrl-Cmd-= to Equalize Splits, as in Ghostty).
- Cmd-Z in a terminal: the shipping cmux sends it to the program; cmux-next routes Ghostty's
  `performable:undo` to Reopen Last Closed Item.
- Cmd-J: Click by Hint in the shipping cmux; the leader key in cmux-next.
