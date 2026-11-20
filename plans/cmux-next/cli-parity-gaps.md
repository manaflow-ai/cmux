# CLI parity: GUI actions with no CLI path (cmux#44937)

Rule (the issue's user): everything a person can do in cmux, an agent can do from the `cmux` CLI.

## What is covered and tested

Every action in the catalog (`cmux-action-catalog`, exported to `action-surfaces.json`) that a
person reaches from the palette, a right-click menu or the main menu has a CLI path:

- `cmux <noun> <verb>` when its CLI surface is `offered`; also `cmux <noun> <id> <verb>` for a
  `kind_<hex>` id target, and `<noun> X` / `<noun> unX` for a toggle with a state argument
  (`cmux workspace ws_… pin`).
- `cmux action run <id>` for the rest (`guiOnly`, `focusMove`, `liveInput`, …): the exemption
  says why it has no named verb, not that a script cannot run it. A bare verb several nouns
  share (`cmux action run pin-unpin`) gets a usage error naming each action it could mean.

Tests that fail when that stops being true:

- `CLISurfaceParityTests.everyGUIActionRunsFromTheCLIByID` (CmuxNextControlTests): each such
  action, run by id over `action.run`, reaches its own handler with the script's origin.
- `cli::tests::action_surface_parity::every_gui_action_runs_by_its_id_with_action_run` and
  `every_offered_verb_takes_its_object_first` (cmux-tui): the CLI sends exactly that id, and each
  offered verb takes its object first.

The Cmd+P list (`goToWorkspace`) runs from the CLI as `cmux action run goToWorkspace` or
`cmux workspace <ws> focus`; its row commands rename and close are `cmux workspace <ws> rename|close`.

## Not covered: menu rows outside the catalog

These rows are built by hand (`NSMenuItem` with a closure, or a chat page action) and call their
model directly, so neither the palette nor the CLI reaches them. Each needs a catalog action,
which lands in two steps (docs/ci/app-ffi-release.md): step A adds the Rust catalog row with an
`awaiting-repin/actions/<id>` marker, and after the re-pin step B binds the Swift handler and
moves the menu row onto the action. Audit of 2026-11-16 at origin/feat-cmux-next 02e22fcdef2:

| Menu rows (file under Packages/macOS/CmuxNext/Sources) | Suggested CLI |
|---|---|
| Browser download Pause / Resume, Retry, Cancel (`CmuxNextApp/Handlers/BrowserDownloadsMenu.swift`) | `cmux browser download pause\|resume\|retry\|cancel --id ID` |
| Browser media card play/pause, previous/next, Picture in Picture (`CmuxNextApp/Handlers/BrowserMediaMenu.swift`) | `cmux browser media play\|pause\|next\|previous\|pip` |
| DevTools Dock to Left (`CmuxNextBrowser/CEF/CEFDevToolsDivider.swift`) | `devtools.openDockedLeft` beside the other dock actions |
| Agent chat message: Retry, Edit and Resend, Pin as Chapter, Fork from Here, Open in Side Chat, Send Prompt Again (`CmuxNextAgentPane/AgentPaneContextMenu.swift`, `AgentPanePromptAgainMenu.swift`) | a `--row` / `--through` argument on the agent actions |
| Agent chat Save Image As… | `cmux agent save-image --row ID --out FILE` |
| Files pane: Duplicate, Make Alias/Symlink, Compress, Expand, Delete Immediately, Paste, Move Here, Show Hidden Files, Undo/Redo, Get Info, Show Package Contents, Go to Folder (`CmuxNextFilesUI/FilesPaneView+Menu.swift`) | `cmux files <verb> --pane P` (at least show-hidden, undo, redo) |
| Screenshots grid Rename, Move to Trash (`CmuxNextFileGrid/FileGridView.swift`) | shell has these; a catalog action for parity |
| Files sidebar Remove from Sidebar, Eject (`CmuxNextFilesUI/FileSidebarView.swift`) | `cmux files favorite remove PATH`, `cmux files eject VOLUME` |
| Mac Screen toolbar: View Only / Full Control, Refresh, Display, Quality, Show Stats, Send Keys (`CmuxNextMacScreen/MacScreenToolbar.swift`) | `cmux tab <tab> mac-screen scope\|display\|quality\|refresh\|send-keys` |
| Mac Screen device: open View Only / Full Control, Ask for Access (`CmuxNextMacScreen/MacScreenHomeDevices.swift`) | `--scope view\|full` on `tab new-mac-screen` |
| Remote Desktop quality preset (`CmuxNextRemoteView/Pane/RemoteHoverToolbar.swift`) | `cmux remote quality PRESET` |
| Menu bar extra Computer Use Take Over / Hand Back (`CmuxNextSettings/MenuBarExtra.swift`) | `cmux computer-use pause\|resume` |
| Markdown Share Copy / Open Live Link (`CmuxNextApp/Pages/Files/MarkdownShare/MarkdownOmnibarBar.swift`) | `cmux open FILE --live-link --print` |
| Chief pet Upload Your Own…, Remove (`CmuxNextChiefPetWiring/ChiefPetSettingsRows.swift`) | `cmux chief pet upload FILE\|--remove` |

Rows left out on purpose: text editing and clipboard rows (Cut, Copy, Paste, Copy Message), page
context menus a web page defines, navigation history entries, and pickers whose choice a setting
already holds (`cmux settings set`).
