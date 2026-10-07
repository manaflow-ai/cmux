# E4 `terminal-compose`: terminal composer, drafts per terminal, todo surface

Status: in progress, 2026-10-07. Lane E4 of [PLAN.md](PLAN.md) wave E, branch
`feat-cmux-next-ios-e4-compose` off `feat-cmux-next-ios`. Closes the D3 parity rows
([d3-dogfood.md](d3-dogfood.md) 1.9 "Todo surface", 1.10 "Terminal composer with attachments, image
paste", 1.10 "Drafts per terminal"). Binding: [a1-shell.md](a1-shell.md) 1.10 and 2.3 (drafts are client
view state), [d1-terminal-ux.md](d1-terminal-ux.md) 4 (one action path per command),
[c1-terminal-rpc.md](c1-terminal-rpc.md) 5 (input path), [c4-files.md](c4-files.md) 3 and 6 (inbox,
`FileSendCoordinator`, quoted path), [c13-viewers.md](c13-viewers.md) 4 (Markdown), ios-keyboard.md
(the keyboard never changes the grid).

## 1. Ownership

| Fact | Owner | Phone |
| --- | --- | --- |
| Terminal input order | the terminal's ordered input queue (C1), then the session host | the composer only produces input actions on that queue |
| Bracketed paste mode (DECSET 2004) | the program in the PTY; the mirror surface tracks it from host bytes | Ghostty's paste encoder reads the mirror's mode |
| Draft text per terminal, sent history | this device (client view state, never synced) | `TerminalComposeStore`, one file under Application Support |
| Uploaded attachment bytes | the Mac inbox (C4) | a quoted path inside the draft text |
| Composer on/off | this device's terminal settings (C11) | `TerminalPreferences.composerEnabled`, mirrored in `TerminalAppearance.showsComposer` |
| Workspace todo list | the Mac file system (a Markdown file in the workspace folder) | a downloaded copy, read only |

## 2. Send contract

A composed prompt is one paste followed by one Return, the same contract as the Mac's text box
composer and the shipping phone composer (`[.paste(text), .return]`):

1. `ComposerSubmission.prepare(_:)` normalizes the draft: CRLF and CR become LF; C0 controls other
   than LF and TAB, DEL and C1 controls are removed (an ESC inside the text could close a bracketed
   paste early and run the rest as keystrokes); trailing whitespace and leading blank lines are
   trimmed. Empty means nothing to send.
2. `TerminalViewController.sendComposed(_:submit:)` runs `[.paste(text), .key(Return), .key(Return
   released)]` on the Ghostty surface. `ghostty_surface_text` wraps the text in `ESC[200~ … ESC[201~`
   exactly when the program enabled bracketed paste, so an agent's line editor takes the whole block
   as one insertion and the single Return submits it once. The encoded bytes leave through
   `onInput`, the same ordered `TerminalSession` queue keystrokes use, as one C1 `TerminalInput {kind:
   bytes}` record each. Nothing queues offline: a closed source drops the send like a keystroke, and
   the draft is cleared only after the screen accepted it.
3. "Insert Without Sending" (send button menu) skips the Return.

`kind: paste` in C1 stays reserved: the phone's Ghostty already encodes the paste against the mirror's
mode, so a host-side paste kind would only duplicate that.

## 3. Composer UI (`CmuxiOSTerminalCompose`)

- An optional bar pinned to `keyboardLayoutGuide.top`, so it rides above the key bar while the
  terminal has the keyboard and above the keyboard while the composer has it; at the bottom safe area
  when no keyboard shows. The grid never changes; the cursor pan (`panToCursor`) keeps the cursor row
  above the bar.
- A growing `UITextView` (1 to 6 lines, then scrolls), an attach button (photos, camera, files through
  C4's `FilePickerCoordinator`), a dictation button (C8's Speech controller, on device when supported),
  a send button (menu: Insert Without Sending, History).
- Return rules (`ComposerReturnRule`): software keyboard Return inserts a newline (Send sends);
  hardware Return sends, Shift-Return and Option-Return insert a newline, Command-Return sends.
  Hardware Up on the first line and Down on the last line walk the sent history.
- Image paste and drop: the text view's Paste takes images and files from the pasteboard
  (`UIPasteboard.hasImages`, file URLs); a `UIDropInteraction` takes dropped images and files. Each
  item is staged by C4's `FileStager` (HEIC to JPEG per the C4 setting) and uploaded to the Mac inbox
  (`dest.kind = composer`); an "Uploading name" chip shows meanwhile. On success the POSIX
  single-quoted path plus a space is inserted at the caret; a failure leaves a chip with Retry and
  Remove. Send is disabled while uploads run.
- Toggle: Settings > Terminal > Composer (C11) and Show/Hide Composer in the terminal More menu; the
  menu writes the same setting, so every terminal follows.

## 4. Drafts and history (`CmuxiOSTerminalComposeCore`)

- Key: `TerminalDraftKey(host, terminal)` (host id + `term_…`). SSH terminals key by the SSH host id
  and their channel id; they get the composer only once C9 passes a key (not in this lane).
- `TerminalComposeStore` (`@MainActor`): drafts in memory, written on edit end, screen disappear,
  backgrounding and send (never per keystroke). Bounded: 100 drafts (oldest edit evicted), 32 KiB of
  UTF-8 per draft, 50 history entries (a repeat moves to newest). Empty text removes the draft; send
  clears it. Sign-out clears drafts and history. File: `Application Support/cmux/terminal-compose.json`,
  `completeUntilFirstUserAuthentication`, decoded tolerantly (a bad file reads as empty).
- `TerminalComposerModel` (`@MainActor @Observable`): text, upload chips, can-send, history cursor
  (keeps the in-progress text while walking), send produces a `ComposerSubmission`.

## 5. Todo surface

cmux-next has no todo surface kind and no checklist op: the daemon lacks `workspace-checklist-v1`
(`WorkspaceMetadataHandlers` binds Add Checklist Item, Toggle, Open Todo Pane as unavailable), and the
mobile tree projects only terminal, browser, agent and other tabs. The phone therefore renders the
workspace's todo file:

- `WorkspaceTodoLocator` picks the first of `TODO.md`, `todo.md`, `TODOS.md`, `todos.md`, `TASKS.md`,
  `.cmux/todo.md` in the workspace root (`files.roots` id = workspace id, C4), from one `files.list` of
  the root (and of `.cmux` when present).
- `TodoSurfaceModel` (`@MainActor @Observable`): locating, missing, loaded (local copy through C4
  download), failed; Refresh re-reads (no polling: there is no file change stream).
- `TodoSurfaceViewController` embeds C13's `MarkdownViewController` (task items as checkboxes, done of
  total in the header) with Refresh and an empty state naming the file names it looks for.
- Entry: a "Todo" row in the workspace detail next to Changes and Files (`WorkspaceViewerOpening.
  todoScreen(for:)`).
- Read only: C4's only write is an upload into a writable root, which would replace the whole file and
  race the Mac's editors. Edits wait for a daemon checklist op (`workspace-checklist-v1`) or a files
  `write` with a precondition on the old digest.

## 6. Tests (Swift Testing)

`CmuxiOSTerminalComposeCoreTests` (macOS through a scratch package, the iOS package declares no macOS
platform): submission normalization (CRLF, ESC and C1 removal, trimming, empty), path quoting and
insertion spacing, Return rules, draft store bounds (count eviction, byte cap on a UTF-8 boundary,
empty removes, send clears, persistence round trip, corrupt file, sign-out), history (dedupe, cap,
walk with stash), composer model (upload chips, path insertion at caret, can-send). `CmuxiOSViewersCore`:
locator priority and the todo model over the mock source.

## 7. Not here

A daemon checklist op and editing todos; per-agent submit keys (Ctrl-Enter for some agents) until the
tree reports the agent per terminal; `@` file and `$` skill completion (needs a files search op); the
composer on SSH terminals.
