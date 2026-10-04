# cmux-next iOS keyboard interactions

Status: audit done, slices proposed, 2026-10-04. Owner: iOS keyboard lead (taken over from
Aziz's agents on Lawrence's instruction, 2026-10-04). Binding: OWNERSHIP-PRINCIPLES.md,
ios-rewrite.md, ghostty-next.md sections 5 and 6 (D5, D6, D8).

Bar: Apple Messages for the Home transcript and composer; a first-class terminal (Blink,
Termius, the Mac Ghostty) for the terminal screen.

## 1. Evidence

Audit run: `ios/scripts/keyboard-uitests.sh` with `nx-remote --sim` on cmux-lawrence-2
(isolated headless iPhone 17, iOS 27.0, one screen recording per test). Tests:
`ios/cmuxUITests/KeyboardAuditUITests.swift` (new UI test target `cmuxUITests` in the
`cmux-ios` scheme; DEV preview, mock owner, no account). Recordings, contact sheets and the
measurement lines are in `.cmux-scratch/nx-worker/ios-keyboard/audit1/` (hq checkout).

| Test | Result | Measurement |
| --- | --- | --- |
| composer rides keyboard | FAIL | keyboard top 590 pt; field stays at y 796..832 under the keyboard; the newest 3 messages are hidden |
| send keeps focus | PASS in the video (test assertion was wrong: the mock replies after a send) | field 502..538 after typing; keyboard stays; field focused |
| composer grows to 5 lines | PASS, with a clip | heights 36, 58, 80, 102, 116, 116: the cap uses `font.lineHeight` (20.3) but lines are 22 pt, so line 5 is clipped by 8 pt |
| interactive dismissal | keyboard follows and closes | mid-drag frames show two bubbles drawn over each other (row motion during the drag) |
| rotation with keyboard up | FAIL | landscape: field at y 30 (top of the screen), transcript empty; back to portrait: field 606..642 under the keyboard top 590 |
| hardware Return / Shift-Return | FAIL or harness gap | nothing typed for either key; a control test is added before this counts as a product bug |
| Cmd-F, Cmd-N on Home; Esc in a conversation | FAIL | no `UIKeyCommand` exists anywhere in the new app (code) |
| search field | PASS | keyboard shows, Search key closes it, results stay |
| invite sheet | PASS | field focused on open, keyboard shows |
| terminal tap | FAIL | no keyboard: nothing calls `focusInput()` and the view has no tap gesture (code) |

## 2. Findings, ranked

S1 (blocks use):

1. The Home compose field does not follow the keyboard. `HomeTranscriptView` places the
   field by frame from `fieldGuide.layoutFrame` in `layoutSubviews`, but a keyboard guide
   change does not run that layout pass. The field moves only when something else asks for
   layout (typing, a send), so the first keyboard show covers the field and the newest
   messages, and rotation leaves stale frames (field at the top in landscape, under the
   keyboard after rotating back).
2. The terminal cannot take input. No tap focuses it; even when focused, the view adopts only
   `UIKeyInput`: autocorrect, smart quotes and dashes and autocapitalization are on (a typed
   `'` becomes `’`), there is no IME or marked text, no hardware key handling
   (`pressesBegan`), no Ctrl/Alt/Esc/Tab/arrows, no accessory bar, Backspace is text `0x7f`
   instead of a Ghostty key event (wrong under Kitty keyboard mode), and the keyboard covers
   the cursor row (no pan; ghostty-next section 6 rule 2 requires it).

S2 (visible defects):

3. Keyboard show and hide move the field with UIKit's keyboard curve but the rows with the
   render core's field spring (`setHostedField` commits a `.field` change): the two curves
   differ, and during an interactive drag the core restarts its spring each frame, so the rows
   trail the finger. Messages moves rows, field and keyboard as one.
4. Rows drawn over each other during the dismissal drag (row motion plus scrolling); needs a
   focused repro after 1 and 3.
5. No hardware keyboard commands: Cmd-F (search), Cmd-N (new message), Esc (back / close
   sheet), Cmd-Return (send from the multi-line field), Up/Down in the list, Cmd-[ (back),
   Cmd-1..9 are missing; nothing shows in the iPad Command-key overlay.
6. Two compose fields with different rules: `HomeFieldView` (conversation: hardware Return
   sends) and `ComposerView` (New Message: Return always adds a line, no hardware handling).

S3 (polish):

7. Field cap clips line 5 by 8 pt (measured line height vs `font.lineHeight`).
8. Transcript accessibility element frames are built once per rows change, not per scroll or
   keyboard move (`HomeRowHostView.elements`), so VoiceOver frames go stale after the keyboard
   moves the rows. To verify with the accessibility inspector after 1.
9. iPad: one scene only (`UIApplicationSupportsMultipleScenes` false); Stage Manager window
   resizes and the floating keyboard (`keyboardLayoutGuide.followsUndockedKeyboard` false)
   are untested. External keyboard on iPhone hides the software keyboard; the field must stay
   on the bottom safe area then (covered by the guide once 1 is fixed).

Checked and fine: search field and invite sheet keyboards, focus after send, interactive
dismissal reaches a closed keyboard, the send button stays enabled state correct offline.

## 3. Target behavior

Home transcript and composer:

- The field's bottom edge is the keyboard guide's top minus 8 pt in every state (show, hide,
  interactive drag, rotation, split view, Stage Manager, hardware keyboard, floating
  keyboard). Rows above it move by the same delta on the same curve in the same frame; during
  an interactive drag they track the finger with no spring.
- When the transcript is pinned to the newest message it stays pinned through every keyboard
  and size change; when the user scrolled up, the row under the top edge keeps its position.
- The field grows one measured line at a time to 5 lines, then scrolls inside.
- After a send the field keeps focus and the keyboard stays.
- Software Return adds a line (Messages). Hardware Return sends; Shift-, Option-Return add a
  line; marked text is never sent.
- Hardware commands (`UIKeyCommand`, listed in the Command-key overlay, localized titles):
  Home: Cmd-F search, Cmd-N new message, Up/Down/Return to move and open; conversation: Esc and
  Cmd-[ back, Cmd-F search, Cmd-Return send. One shared action path per command (the same
  action the bar buttons run).
- One compose field type for the conversation and New Message.

Terminal (ghostty-next section 5, decisions D5, D6, D8):

- Tap focuses the terminal and shows the keyboard (user action only).
- The view adopts `UITextInput`: autocorrect, smart punctuation, spell check, autocapitalize off,
  `.asciiCapable` by default; marked text goes to `ghostty_surface_preedit` and is never sent;
  `caretRect`/`firstRect` come from `ghostty_surface_ime_point`; `insertText` goes to
  `ghostty_surface_text_input`; Backspace is a Ghostty key event; hold-to-repeat Backspace
  works with an empty document (zero-width anchor, as the old app did).
- Hardware keys: `pressesBegan/Ended` -> `ghostty_surface_key` (physical code, mods,
  characters, unshifted codepoint); Command combos go to app commands first; Option as Meta is
  a setting (`ios.terminal.optionAsMeta`, default true).
- Accessory bar above the software keyboard (hidden with a hardware keyboard): Esc, Tab, Ctrl
  and Alt (sticky one-shot, double tap locks), an arrow pad, `~ / | -`, paste, hide keyboard;
  the key set is the setting `ios.terminal.accessoryKeys`.
- The grid never changes for the keyboard (D8); the view pans so the cursor row stays above
  the keyboard and the bar, with the keyboard curve.
- No lost first key: the first key after focus reaches the host.

## 4. Slices (red test first, then the fix)

| # | Slice | Red test | Files |
| --- | --- | --- | --- |
| K1 | Field follows the keyboard guide in every layout | UI: `testComposerRidesKeyboardAndNewestMessageStaysVisible`, `testRotationKeepsFieldAndNewestMessage` | `CmuxHomeUI/Transcript/HomeTranscriptView.swift` |
| K2 | Rows move with the field on the keyboard's curve; no spring during a drag | unit: core reports an instant field move; UI: per-frame gap between newest row and field constant in the recording (frame-split check) | `HomeTranscriptView.swift`; additive `CmuxHomeRender` API (`setHostedField(_:send:animated:)`) through lane 16 |
| K3 | Field line cap from measured lines | unit on `HomeFieldView.preferredHeight` | `HomeFieldView.swift` |
| K4 | One compose field (New Message uses `HomeFieldView`'s rules) | UI: hardware Return in New Message | `Compose/ComposerView.swift`, `HomeFieldView.swift` |
| K5 | Hardware commands for Home and conversation | UI: `testHardwareShortcuts`, `testEscapeLeavesConversation` (after the harness control passes) | `HomeViewController.swift`, `ConversationViewController.swift`, `HomeText` (en, ja) |
| T1 | Terminal focus + `UITextInput` traits + text path | unit (view, no window server): traits, `'` stays `'`, Return sends CR | `CmuxiOSTerminal/Ghostty/GhosttyTerminalView*.swift` |
| T2 | Hardware keys through `ghostty_surface_key` | unit: Ctrl-C, arrows, F-keys, Option-as-Meta bytes from the mirror surface | `GhosttyTerminalView+Keys.swift`, HID -> native key code map |
| T3 | Accessory bar with sticky modifiers | UI: `testTerminalTapShowsKeyboardAndKeyBar`; unit: sticky Ctrl + `c` = 0x03 | `CmuxiOSTerminal/Input/TerminalKeyBar*.swift`, settings keys |
| T4 | Marked text / preedit and caret rect | unit: `setMarkedText` sends nothing, `unmarkText` sends once | `GhosttyTerminalView+TextInput.swift` |
| T5 | Cursor pan above the keyboard | UI: cursor row rect above keyboard top after focus | `TerminalViewController.swift` |
| A1 | Accessibility: per-scroll element frames, Dynamic Type at AX5 with keyboard up | UI with `content_size` AX5 | `HomeRowHostView.swift` |

Device proof on "Lawrence's iPhone" (E4058DA9-...) for K1, K2, T1-T3 once its Tailscale is on
(fleet compile, local install queue, dogfood launcher; no laptop rebuild loops).

## 5. Owners

| Area | Owner |
| --- | --- |
| `ios/CmuxiOS/Sources/CmuxHomeUI/Transcript`, `Compose`, `Public` (keyboard, commands) | iOS keyboard lead |
| `ios/cmuxUITests`, `ios/scripts/keyboard-uitests.sh` | iOS keyboard lead |
| `Packages/Shared/CmuxHomeRender` host API (field move without spring) | lane 16 (Mac Home rendering); additive change proposed through the coordinator |
| `ios/CmuxiOS/Sources/CmuxiOSTerminal/Ghostty` input side | iOS keyboard lead; C API questions to lane 13 (ghostty-next) |
| GhosttyNextKit (iOS native key code = mac virtual key code today; preedit and ime_point) | lane 13 |
| `TerminalSessionSource.send` ordering and attribution | lane 12 (transport) |

## 6. Decided (coordinator, 2026-10-04)

- KB1: the terminal grid never changes for the keyboard; the view pans so the cursor row stays
  visible (D8). The brief's "resize the grid" was the coordinator's wording, not Lawrence's.
- KB2: printable hardware keys without Ctrl/Alt go through the text system (hardware IME such
  as Japanese Romaji keeps working); Ctrl, Alt and special keys go through
  `ghostty_surface_key`. Known limit: Kitty keyboard "report all keys" mode gets no press
  events for plain printable keys.
- KB3: the keyboard lead adds `setHostedField(_:send:animated:)` to `CmuxHomeRender`
  (additive, red test first); lane 16 is told to expect it.
- KB4: lane 13 is asked to make the iOS native key code the USB HID usage; until then the app
  maps HID usage to the mac virtual key code with a physical-key table generated from
  `keycodes.zig` (not an encoding table; D5 holds).
- The terminal uses the shared CmuxGhosttyKit pin from the ghostty-next lead's S2
  (apple-v6), never the a7c40619a or 3e9dfca98 releases.
- Hardware-key UI results count as product bugs only after the harness control test
  (`typeKey("x")`) passes.
