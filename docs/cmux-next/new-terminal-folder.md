# Where a new terminal starts

A new terminal (a new workspace's first terminal, a new tab, a split) starts in
the first folder of this list that applies:

1. **The folder its caller names**: `cmux new-workspace --cwd DIR`, `cmux open DIR`, any CLI `--cwd`,
   a template or a restored session.
2. **A new workspace's room folder**: the room's (profile's) `defaults.cwd`.
3. **The folder it inherits**, while Ghostty's `window-inherit-working-directory`
   (new workspace), `tab-inherit-working-directory` (new tab) or
   `split-inherit-working-directory` (split) is true, the default: the focused
   terminal's folder (its OSC 7 report), or the focused agent chat's folder; for
   a tab or split, then the daemon's pick among the workspace's terminals
   (`cmux-tui-core/src/mux/new_terminal_cwd.rs`).
4. **Ghostty's `working-directory`**: a path, `~/path` or `home`. `inherit`, an
   unset key, a relative path or a folder that no longer exists skip this step.
   The key is read from the loaded Ghostty config files in load order
   (`~/.config/ghostty/config`, then `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`,
   then their `config-file` includes); a later line wins.
5. **The home folder.**

Steps 2 and 4 apply only on this Mac's daemon: a Cloud or SSH machine keeps its
own default, since a Mac path means nothing there.

Code: `CmuxNextApp/NewTerminalStart.swift` (`defaultFolder(on:)`, `uninherited`,
`inherited`), `CmuxNextAppCore/WorkspaceSpawn.swift` (`startFolder`),
`CmuxNextTerminal/GhosttyRuntime+WorkingDirectory.swift` and
`CmuxNextTerminal/GhosttyConfigWorkingDirectory.swift`.
