# Dialog key hints: audit (u2647)

Request: every dialog, sheet, alert, confirmation, approval prompt and popover with actions
shows the key that presses each button (Cancel ⎋, Change ↩, Don't Save ⌘D), and the key
really presses it. Trigger: the settings approval sheet "Change browser.searchEngine?"
(Cancel / Change, no keys shown).

## One rule, four renderers

| Surface | Shared component | Key binding |
| --- | --- | --- |
| Native cmux dialogs (`CmuxDialogSpec` through `CmuxDialogCenter`) | `CmuxDialogButtonView` draws `CmuxDialogKeys.hint(for:in:)` | `CmuxDialogKeys.action` (the same rules, inverted) |
| AppKit sheets and panels (`ThemedBezelButton`, `ThemedDefaultButton`) | `ThemedBezelButton.keyHint` | sets `keyEquivalent` + mask from the hint |
| SwiftUI sheets | `CmuxDialogActionButton(title, hint:)` | `.keyboardShortcut` from the hint |
| Web dialogs (`ui/Dialog`, `ui/Sheet`, Home `FormDialog`) | `ui/DialogButton` (`dialogKey`) | Return/Escape by the dialog (form submit, ui/Dialog); Command keys by the button |

All four draw the same glyphs (`↩`, `⎋`, `⌘X`) after the title in the secondary text
color at caption size; the accessible name stays the title, the key is read as help
(VoiceOver: "Return", "Escape", "Command-D", 21 locales) or `aria-keyshortcuts` on the web.

Guard: `scripts/cmux-next/check-dialog-key-hints.py` (CI step "Dialog buttons show their
keys" in cmux-next.yml, `bun run check` in webviews) fails on `.keyboardShortcut(.defaultAction
| .cancelAction)`, a hand-set `keyEquivalent = "\r"` / `"\u{1b}"`, SwiftUI `.alert(` /
`.confirmationDialog(`, `NSAlert(`, and a raw dialog-class `<button>` in a web dialog file.

## Inventory

### Native cmux dialogs (covered by the shared view, no per-site change)

Every `CmuxDialogSpec` gets hints from `CmuxDialogView`: the default button ↩, the cancel
button (or the only button) ⎋, a button with `key` ⌘key. A `.normal` button with no `key`
shows none (no key presses it).

- Settings approval (`UserOnlySettingConfirmation`) and every `DestructiveConfirmation`
  prompt: Cloud kill machine, delete snapshot, remove file, delete firewall rule; close
  workspace / group workspaces / bulk closes (`WorkspaceBulkClose`); browser profile delete;
  agent extension access; delete space (`RoomStrings`); remote install
  (`RemoteConfirmation`); tab group close (`TabCloseGuard`); delete command history;
  workspace localhost (`RemoteLocalhostHandlers`); incognito window close.
- Quit: `QuitAlert`, `QuitFailureAlert`, `QuitUnsavedStep` (Don't Save ⌘D).
- `RenamePrompt`, `DebugDialog`, `CloudPresenter`, daemon pairing approval, daemon recovery
  controls, terminal clipboard read requests (`TerminalClipboardRequests`,
  `TerminalClipboardReadService`), page confirmations (`PageConfirmation`).
- Browser: JavaScript alert/confirm/prompt (`BrowserPromptDialogs`), HTTP auth
  (`BrowserHTTPAuth`), extension prompts (`ExtensionPromptSheet`, `CEFExtensionPrompts`),
  remote browser JS dialogs (`RemoteBrowserNativeUI`, `RemoteBrowserPages`).
- Onboarding and passwords: bookmark browser import, browser file import, Firefox primary
  password, password CSV column sheet and guide, native password secret surface.
- Agent pane: harness enable, reply links, transport prompts.
- Share cmux (`ShareCmuxView`): Copy Link ↩ (Return presses it while it has focus).

### AppKit sheets and panels (migrated to `keyHint`)

| Site | Buttons |
| --- | --- |
| `HomeSheetController` (Home New Message, Invite, New Chief) | Cancel ⎋, primary ↩ |
| `CookieImportConsentPanel` | Deny ⎋; Allow has no key on purpose (a consent prompt never allows on Return) |
| `CloudMachineProgressView` | Retry ↩; Copy Error / Dismiss no key (the page keeps Escape and typing) |
| `MachineBrowserPageTab` | Open Locally ↩ |
| `SiteDataWindow` | Done ↩ |

### SwiftUI sheets (migrated to `CmuxDialogActionButton`)

| Site | Buttons |
| --- | --- |
| `BookmarkEditorSheet` | Cancel ⎋, Save ↩ |
| `BookmarkEditView` (bookmark bubble) | Done ↩; More / Remove no key |
| `HistoryCookieBackupsView` | Done ↩; the system `.confirmationDialog` is replaced by an in-sheet confirmation: Cancel ⎋, Delete Backups ↩ |
| `ConnectConfirmation` (Accounts) | Connect ↩, Cancel ⎋ |
| `UpdateSheetView` | last button ↩, first other closing button ⎋ |

### Web dialogs (migrated to `ui/DialogButton`)

| Site | Buttons |
| --- | --- |
| Home `FormDialog` sheets: New Message, Invite, New/Edit Chief, Archive Chief, Unavailable notice | Cancel ⎋, primary ↩; Chief picture buttons no key |
| Cloud `CreateSheet` | Cancel ⎋, Create ↩ |
| `PathPicker` | Cancel ⎋; Choose This Folder no key (Return chooses the highlighted row; its footer hint already says ↩) |
| Home attachment lightbox | Close ⎋ |

### Not changed, with reason

- System open/save panels (`NSOpenPanel`, `NSSavePanel`, print): Apple draws them; they
  already follow the macOS Return/Escape rules and cannot carry custom hints.
- Browser permission prompt bar (`PromptBarView`): a non-modal bar over the page; Return and
  Escape belong to the page, so the bar binds none (its text fields answer Return/Escape).
- Icon-only viewer controls (acpmux `ImageViewer`, `GalleryDialog`, `ReplyMedia`): image
  viewers, not decisions; Escape closes them and the close button has a tooltip. Follow-up:
  add `aria-keyshortcuts` and a tooltip keycap.
- acpmux `AddProjectPanel`: already shows a key legend in its footer (⌘↩, ↑↓, ↩, ⌥←, Esc).
- Inline hints and chips (`TabOverflowHintView`, `HomeFirstRunSwitchCard`,
  `TerminalSizedForChip`, `BrowserFitFrameView`, Feed approve controls): not dialogs; giving
  them Return or Escape would take those keys from the terminal or page.
