# Navigation, Photos crash, dead controls, Feed quotes: verification

Branch `feat-cnx-ios-nav`, 2026-10-13. The work responds to four pieces of user feedback:

- Back swipes and back buttons on drill-down screens.
- A crash from the Photos menu item.
- Controls that do nothing.
- Feed quote bubbles that should be right-aligned.

## How it was verified

- `verify/build.sh` (xcodegen and a Debug simulator build), installed on two headless iPhone 17 Pro
  simulators: `cnx-nav-ios26` (iOS 26.5) and `cnx-nav-ios27` (iOS 27.0). The app ran with
  `CNX_MOCK_AUTH=1`. Simulator.app was never opened.
- Taps and swipes were real HID touches sent with `axe`, so they took the production gesture path. No demo
  driver was used. `verify/swipe-rec.sh` records each drag with `simctl io recordVideo` and splits it into
  10 fps frames. Edge swipes start at x = 1 pt. Full-width swipes (iOS 26 content pop) start mid-screen.
- `simctl addmedia` seeded the photo library with two images.
- Crash logs came from `~/Library/Logs/DiagnosticReports/CnxApp-*.ips`.

The evidence is git-ignored, in `verify/evidence/2026-10-13/nav/`:

| Path | What |
| --- | --- |
| `nav/<sim>-summary.png` | One strip per simulator, each screen as pushed and after its back swipe |
| `nav/<sim>-*-frames/` | 10 fps frames of each recorded swipe (interactive pop in progress) |
| `fp.png` | Before: an edge swipe on a Feed chat opened the team drawer |
| `fp3.png`, `feed-pop2.mp4` | After: the same swipe pops the chat interactively |
| `photos/` | The Photos flow from every composer (menu, picker, attached, sent), both simulators |
| `feed/before-*`, `feed/after-*` | Feed quote bubbles, light and dark, three scroll positions, both simulators |
| `CnxApp-*.ips` | The three crashes found and fixed (Photos TCC, workspace push, terminal after pop) |

## Transitions

"Push" means a NavigationStack push with the system back button, the edge swipe, and on iOS 26 and later
the full-width swipe. "Modal" means a sheet for a task.

| Transition | Before | After | Verified |
| --- | --- | --- | --- |
| Home → agent chat (conversation row) | Push | Unchanged | Full-width swipe pops, both simulators |
| Home → Chief | Push with Chief's own glass back button and the bar hidden | Unchanged. The CnxChief presentation agent owns this | Not recorded here |
| Workspaces → workspace (TabsKit) | Push with the bar hidden. **Crashed on open**: the terminal tab nested a SwiftUI `NavigationStack` in the pushed page, and with the typed `[Workspace]` path SwiftUI trapped (`comparisonTypeMismatch`). The back swipe was dead: SwiftUI disables the iOS 26 content pop while the bar is hidden | Opens. The path is a `NavigationPath`. The terminal page has its own UIKit navigation controller, so no SwiftUI stack is nested. The edge pop and full-width content pop are re-enabled with a delegate that allows them only when there is something to pop. The back chevron stays bottom-leading in the TabsKit toolbar | Edge and full-width swipes pop, both simulators |
| Leaving a workspace with a terminal tab | **Crashed** (`EXC_BAD_ACCESS` in `CnxGhosttyApp` action callback): Ghostty delivered an action to a freed `TerminalSurfaceView` | The surface userdata is its `InputBox`. It outlives the view until `ghostty_surface_free` and holds the view weakly | Full-width pop out of a workspace, no crash |
| Workspace grid back circle and "All Workspaces" | Pop | Unchanged | — |
| Feed event → agent chat | Push, but the Feed path was private, so the shell thought Feed was at its root. **An edge swipe opened the team drawer instead of going back** | The Feed path is the shell's `feedPath`. The drawer pan also refuses to begin when the touched navigation controller has anything to pop, so no stack depends on reporting its depth | Edge swipe pops, both simulators (`fp.png` → `fp3.png`) |
| Agent chat → Changes / diff file | Push (`navigationDestination(item:)`) | Unchanged | — |
| Settings → Account, Team, Paired Macs, Terminal, Composer, Notifications, Acknowledgements | Push | Unchanged | Edge swipe pops the Team page, both simulators |
| Settings and sidebar → Color and emoji | Sheet (editor) | Unchanged (modal task) | — |
| Terminal → Files and links → artifact | Sheet with its own stack. The preview pushes inside it | Unchanged (modal task with drill-down inside) | — |
| Composer `+` → Photos / Files | Sheets (pickers) | Unchanged. Camera is now a full-screen cover, shown only when a camera exists | Photos from each composer |
| Welcome → email sign-in, first-run setup, new workspace | Sheet and stacks | Unchanged. Login, onboarding and creation are owned by other agents | — |

The drawer and back swipes follow SPEC 3.3 (the drawer pan requires the back recognizers to fail). The
drawer pan now also returns early in `gestureRecognizerShouldBegin` for any pushed screen under the touch.
The new `EdgeSwipePriority` recognizer makes a horizontal scroller under an edge touch wait for the edge pop
to fail. Without it, a swipe that started on a markdown table scrolled the table instead of going back.

No `fullScreenCover` or hidden navigation bar remains on a drill-down, except two:

- The TabsKit workspace draws its own chrome. Its back swipes are explicitly re-enabled.
- Chief is not in scope for this branch.

## Photos crash

- Root cause: the Chief composer's Photos item opens `ConversationPhotoGrid`, which calls
  `PHPhotoLibrary.requestAuthorization`. The generated Info.plist had no `NSPhotoLibraryUsageDescription`,
  so TCC killed the app (`namespace: TCC`, `CnxApp-2026-10-13-104812.ips`). The agent chat and terminal
  composers use `PhotosPicker`, which needs no permission. They did not crash.
- Fix: `project.yml` adds three usage strings. `NSPhotoLibraryUsageDescription` reads "cmux uses your photos
  to attach images to messages." `NSCameraUsageDescription` covers the Chief camera item and the agent
  chat Camera item. `NSMicrophoneUsageDescription` covers the conversation audio recorder.
- After the fix, the permission prompt shows the string. "Allow Full Access" loads the grid, on both
  simulators.
- The agent chat composer worked on both simulators: Photos, pick, attach, send. The mock streamed the turn
  with no error state.
- The terminal composer worked on iOS 27: Photos, pick, attach.
- Picking a photo in Chief's mock still reports "Chief can't take photos yet" (`ChiefMockBackend.uploadImage`).
  That belongs to the Chief agent.

## Image attachments over acpmux

`AcpmuxSessionSource` used to drop attachments and send only a text block. A prompt is now ACP content
blocks: the text block, if there is text, then one `{type: "image", mimeType, data: base64}` per image.
The MIME type comes from the data's signature (PNG, JPEG, GIF or WebP). The composer re-encodes other
formats, such as HEIC, as JPEG. File chips carry no contents yet, so they are not sent. Unit tests:
`PromptBlockTests` in `Tests/CnxLiveTests`. `CnxLiveTests` passed on the iOS 26.5 simulator with
`xcodebuild test -scheme CnxKit-Package -only-testing:CnxLiveTests`: 23 tests in 9 suites. The tests ran
locally because `nx-remote` could not resolve `cmux-lawrence-2`.

## Dead controls (no-op audit)

The audit covered every module except CnxChief, CnxOnboarding, workspace creation and empty states, and
toggles.

| Control | Resolution |
| --- | --- |
| Agent chat composer `+` → Camera (`{}`) | Implemented: system camera in a full-screen cover, adds the photo as an attachment. Hidden when there is no camera (simulator) |
| Agent chat title menu: Rename, Open terminal, Files | Removed (no session rename API, no tab routing from a chat) |
| Agent chat toolbar: New session | Removed |
| Agent chat More: Archive | Removed |
| Answer More: Fork from here, Report issue | Removed |
| Sent user bubble attachments: X badge with an empty action | Badge removed on sent attachments (`AttachmentThumb.remove` is optional) |
| Diff file header menu: Open file, Open in terminal | Removed (Copy path stays) |
| Diff line context menu: Comment (coming soon, disabled), Open file at line | Removed |
| Terminal title menu: New terminal tab | Removed |
| Workspaces Mac section More menu: Pair Details, Reconnect, Unpair | Menu removed (no pairing management yet) |
| Workspaces list pull to refresh (`.refreshable {}`) | Removed |
| Settings → Paired Macs: Unpair swipe, Pair a Mac, Disconnect all | Removed |
| Settings → Team: Leave team (showed "isn't available yet") | Removed |
| Sidebar team context menu: Leave team (same toast) | Removed |
| Workspaces empty state: Scan QR code, Enter code manually | Not changed (empty state owned by another agent) |
| Composer mic button | Kept: it focuses the field for keyboard dictation |

## Feed quote bubbles

Your own message is now an outgoing bubble on the right:

- The trailing edge sits at the cell's margin.
- The tail is at the bottom-trailing corner.
- The "You" label is right-aligned.

The agent's reply stays left-aligned below it. A quote the agent asked you ("Asked you") stays on the
leading side with its thread line. Checked on question, permission, response, failed and finished cells,
collapsed and after "Show more". Light and dark, both simulators: `feed/before-*` against `feed/after-*`.

## Open items

- With the composer expanded (attachments or focus), the agent chat transcript can sit about 20 pt left of
  its margin until the next turn arrives. This was seen before these changes. Not fixed here.
- Inside a workspace, the terminal tab's own title bar is not drawn, and its composer sits under the TabsKit
  toolbar. This predates the branch: the embedded terminal variant is still to come.
