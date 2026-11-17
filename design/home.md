# Home in React: the Messages view, its panels and sheets

The docked Home's Messages view (the sidebar's Home entry): the conversation list on the left, one
conversation's transcript and composer on the right, and the panels and sheets they open. Today it is
AppKit (`Packages/macOS/CmuxNext/Sources/CmuxNextHome`, `CmuxNextApp/Home`, `TopPages/TopHomePageView`,
about 19,600 lines). It moves to the shared React web under `webviews/`, a seam at a time.

## The ask (Leo, 2026-11-06)

> "we ought to have a lot of that ui in react and not swift"

> "what are the other bits that are like 'why is this in swift anyway'"

## What stays native

Swift keeps only a thin host bridge:

- **Where Home lives.** The dock tab (`HomeDockTab`, `HomeDockView`), the sidebar's Home and Channels
  entries, focus, and the window's traffic-light inset.
- **The data.** `HomeService`, `HomeStore` and the engine (`CmuxNextHomeEngine`) keep owning
  conversations, the Chief, pins and colours. The React views read and change them through page ops.
  They never write a model of their own.
- **What only the system can do.** The system colour panel, Finder promised-file drags, dictation,
  and the open and save panels. Each is one page op.

## The bridge

Every Home page is a `PageWebView` with a `PageDescriptor` and one `PageRoute` per namespace,
`cmux.home.<surface>.*`. The pattern is the icon picker's (`IconPickerService`,
`webviews/src/pages/icon-picker/host.ts`):

- **One page per surface, kept and reused.** Opening it again sends a new `session` event (the
  conversation, its name, the current values). A late reply carries the session id and never applies
  to a newer session.
- **Changes go through the same code as the CLI and palette.** A colour pick runs
  `HomeChatColorStore.set`, which is also what `cmux chat colors` runs.
- **State flows one way.** The host streams the current values after every change (`state` events).
  The page draws only what the host last sent, so a CLI change while the panel is open redraws it.
- **Paired with the Cloud UI lane.** The same shape is used there (`cmux.cloud.*`). Shared pieces live
  in `webviews/src/pages/shared/`.

## Seams

Each seam lands on its own. It hosts the React view in place of the AppKit one and deletes that Swift
in the same PR. A seam never switches a working Swift path off before its React replacement works.

1. **Chat Colors** (`ChatColors/`): the app's floating panel, opened from a chat row's menu, the
   palette and `home.chatColors`. It opens apart from the Messages view, so it moves on its own and
   sets the bridge pattern.
2. **The Messages view** (`Sidebar/`, `Conversations/`, `NewMessage/`, `NativeTranscript/`,
   `LinkChips/`, `McpConnect/`, `Dock/`, `TopHomePageView`, `HomeHostView`, `HomeNewMessageView`):
   the list, the transcript, the composer, the sheets it opens (Requests, Group Info, New Chief, Team
   Invite, Invite), New Message, and the cards drawn in a chat (agent pills and side pane, link chips
   and previews, the MCP connect card, the first run). These pieces cannot be React while the view
   around them is AppKit (a web view per row or sheet costs too much and splits focus), so they move
   together as one page, `home-messages`. It reuses the Channels page's data layer
   (`webviews/src/pages/home-channels/store.ts`, `daemonHome.ts`, `cloudHome.ts`). The React parts
   land first, each as page code with gallery entries and tests, in this order:
   1. the page shell and the conversation list (search, filters, pins, unread, rows);
   2. the transcript and composer (bubbles, read receipts, attachments, drop, dictation, diagrams);
   3. the sheets and New Message;
   4. the in-chat cards (agent pills, link chips, MCP connect, first run).

   One PR then hosts the page in the dock in place of `TopHomePageView` and deletes the AppKit
   views. The engine models the engine itself reads (`HomePins`, `HomeChiefAvatar`, `ChiefBackend`,
   `HomeGroupOutcome` and the rest) move into `CmuxNextHomeEngine` first.

## Messages

The Messages view is React: the docked Home, classic Home's top page and a Home pane tab all host
`home-messages` (`HomeMessagesPage`, one page kept and reused per host). The AppKit list, sheets and
New Message are deleted. Conversation tabs and the Chief panel host the same page for one
conversation (`HomeConversationPage`, `#/conversation/<id>`: no list column, no compose button), and
the native transcript (`HomeHostView`, `NativeTranscript/`) is deleted.

- **Chief.** The name pill of a Chief chat sends its box (`chief.settings {conversation, anchor}`), and
  the app's Chief settings popover opens under it (`HomeChiefSurface`, the same popover and rows). While
  the Chief answers, the composer's emoji button is Stop (`chief.stop {all}`; Option-click stops all its
  agents), as the native compose bar's was.
- **First run.** The app streams the empty Chief chat's facts (`firstRun`: intro, memory offer,
  shortcuts, agents, switch keys, starter facts) and runs its rows (`HomeMessagesFirstRunProvider`); the
  welcome still plays in the chat itself.
- **Links.** On a one-conversation page every link, a conversation link too, is the app's to open, so
  the tab never turns into another conversation.

Picked list: `messages` (a neutral selection slab and hairlines between rows), over `accent` and `quiet`.
Picked transcript: `imessage` (blue mine, grey theirs, tails on each group's last bubble), over `theme` and `outline`.

## Chat Colors

One chat's bubble and text colours, with a live preview. It opens as a small floating panel, one for
the app. Opening it for another chat switches the panel to that chat.

- **Preview.** A sample of their message ("How do these colors look?") and of yours ("Looks good to
  me!"), in the colours the chat would draw with, on the chat's page colour.
- **My Messages and Their Messages**, each with two rows:
  - **Bubble.** Default (a slashed circle), then the swatches, then Custom Color (the system colour
    panel).
  - **Text.** Automatic (readable on the bubble), white, black, then Custom Color.
- **Swatches.** Mine: Messages' blue first, then the colours Messages and the system use most
  (`#0A84FF #34C759 #AF52DE #FF2D55 #FF9500 #FFD60A #30B0C7 #8E8E93`). Theirs:
  `#E9E9EB #3B3B3D #D6EAFF #D9F7E0 #EADCF8 #FFE5CC #1C2A4A`.
- **Picking.** A pick is stored at once, and the open chat redraws as you pick. The selected swatch
  has an accent ring 3 px outside it.
- **Buttons.** Reset to Default is enabled only when the chat has colours of its own. Done (↩) closes
  the panel. Escape closes it too.
- **Width and order.** 340 pt wide. The panel's height follows its content, and nothing moves while
  you pick: the preview and every row keep their place, and only colours change.
- **Keys.** Full keyboard access tabs through the swatches; Space and Return press them.

Gallery: `home.chat-colors` (variants: default, custom colours on both sides, a chat with only text
colours, dark and light). The picked layout is recorded here when it lands.

Picked: `rows` (the AppKit panel's layout: each row's label in a 48 pt column beside its swatches),
over `caption-labels` and `grouped`, on the 4 pt grid: 340 x 340 pt.

## Rules every seam keeps

- **Constant interaction cost.** The list and the transcript render the visible window first, and
  off-screen rows are deferred (`useTimelineWindow`). A chat with 10,000 messages opens as fast as one
  with 10.
- **A change is a state transition.** A sheet, a panel or a new row moves every affected element
  together, with no layout jump and no pop-in after it lands.
- **Strings.** Each page's strings live in its own `Localizable.xcstrings` next to it, with the same
  keys as the Swift catalog they replace (`home.chatColors.*` and the rest), so translations carry
  over.
