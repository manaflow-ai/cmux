# Reference capture: Claude, ChatGPT (Codex), Grok on iOS 26

Captured on a real iPhone (1320x2868) through TapKit, 2026-10-12. Raw
screenshots are kept outside the repo (private content). What all three
agree on is the default for cmux-next; where they differ, the choice is noted.

## Shared language (all three)

- True-black dark background; chrome is floating Liquid Glass circles and
  capsules, never a solid nav bar. Content scrolls under them with the soft
  top and bottom scroll edge effect.
- Top bar: left glass circle (menu/back), centered title or segmented mode
  switch (ChatGPT Chat|Work, Grok Ask|Imagine|Build), right glass capsule
  grouping 1-2 actions (new chat, ...).
- Composer: rounded-rect glass card (~22pt radius) floating over content.
  Row 1 text, row 2 `+` circle, model pill, mic, primary circle. Primary is
  voice when empty and becomes a send arrow (white circle) when text exists;
  becomes stop (square) while generating. After send, ChatGPT collapses the
  composer into a one-line capsule ("Follow up") and dismisses the keyboard.
- `+` opens a native glass UIMenu (ChatGPT: Camera, Photos, Files, Plugins;
  Grok: Camera, Photo or Video, Files | Connectors, Skills). Claude uses a
  sheet with a horizontal recent-photos strip + rows. Chosen: native menu
  (2 of 3), Photos opens the inline PHPicker sheet ("Select up to N").
- User message: right-aligned rounded bubble (gray in Claude/Grok, tinted in
  ChatGPT). Assistant text: no bubble, full width.
- Code card: header with language label + copy button, monospaced body,
  horizontal scroll, no line numbers. Diffs: red/green text, no row fills.
- Under an answer: small icon action row (copy, thumbs, share, ...).
  `...` opens a menu with timestamp header, Branch, Read aloud, Retry.
- Long-press a bubble: lift + menu with timestamp header, Copy, Select text,
  Share. Select text selects inline with the system edit menu.
- Jump-to-bottom: small glass circle with a down arrow just above the
  composer (Grok right-aligned, ChatGPT centered). Hidden at bottom.
- Working state: shimmering "Working" text (ChatGPT), streaming text.
- Empty states: centered SF Symbol, title, one-line secondary, white capsule
  CTA, optional secondary text button.
- Failure: inline card in the transcript (Grok "High Demand") with icon,
  title, body and white CTA; list-level failure: cloud icon + "Couldn't load
  ..." + Retry capsule (Codex).
- Settings: sheet with glass X, centered title, inset grouped lists with
  leading line icons, chevrons, destructive "Log out" alone in red at the
  bottom, version footer. Grok floats a "Search settings" field at the bottom.
  Codex settings: Connections (status dot + toggle + Add connection +
  Disconnect All), Composer (dismiss keyboard after sending, follow-up
  behavior Queue/Steer), Behavior (wrap code diff lines, Live Activities),
  Require Face ID.
- Sidebar: ChatGPT and Claude push the whole screen right with a rounded
  card edge; Grok is a full-screen page. Pan anywhere to the right opens it
  (ChatGPT), swipe left closes. Items: icon rows, then recents, "See all"
  expands inline, primary "New chat" capsule bottom-left, settings circle
  bottom-right. Context menu on rows: Pin, Rename, Delete (red).
- Menus for filters/sorts are native pull-down menus with checkmarks
  (Codex title menu: Priority / By project / Chronological, Manage section,
  usage footer; Scheduled: Active/Paused/Completed).
- Creation sheets: name field with emoji icon, suggestion chips, primary
  button docked above the keyboard, disabled until valid (New project).
- Paywall (Grok): full sheet, X, title, segmented plans, plan cards with
  check, white CTA, feature list with icons, legal footer links.

## Remote-device pairing (Codex = closest analogue to cmux)

1. Empty state "Connect your computer": icon, title, body, "Scan QR code"
   white capsule, "Enter code manually" text button.
2. Intro: icon + "Get pairing code" + where to find it on desktop, Continue.
3. QR scanner: rounded camera viewport with yellow corner guides, "Scan QR
   code to pair", outlined "Pair manually instead".
4. Manual sheet: "Pair manually", 4 + 4 code boxes separated by a dash
   (XXXX-XXXX), Pair button disabled until complete.
5. Setup screen when no desktop yet: icon, title, two explanatory rows,
   "I'm signed in on desktop" (primary) + "Email me a download link".
cmux uses exactly this flow; our Worker codes are XXXX-XXXX.

## Gestures observed

- Pan right anywhere (fast) opens the ChatGPT sidebar; slow edge pan does
  not. Pan left closes it.
- Pushed settings pages support the interactive edge swipe back; the Codex
  pairing flow (full-screen cover) does not; we use a navigation push.
- Sheets dismiss with a downward swipe; ChatGPT Settings (full screen) does
  not, only X. We use a sheet with swipe-to-dismiss.
- Wide tables scroll horizontally inside the transcript.
- Chip tabs (Library) do not page with horizontal swipes.

## Applied to cmux-next native

- Terminal screen = chat screen: floating glass top controls, Ghostty
  content under them with soft scroll edge effects (non-TUI), composer card
  at the bottom with `+` native menu (Photos, Camera, Files), special-keys
  row, send arrow / stop (Ctrl-C) state.
- Feed = X timeline with Claude-like post cells: avatar, agent name ·
  workspace, time, iMessage quote bubble of the prompt, WebView markdown
  body, "See more", Reply row; inline reply composer.
- Sessions list = ChatGPT sidebar-style list with Codex title menu (host
  switcher + sort + manage), glass search at the bottom.
- Pairing = Codex flow above.
