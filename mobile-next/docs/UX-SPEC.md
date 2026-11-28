# cmux iOS UX reference spec (from popular AI and coding agent apps)

Researched 2026-10-12. Target: native SwiftUI, iOS 26/27 Liquid Glass. Reference images are in `/tmp/cmux-ios-refs/<app>/` (75 files).

How sure each point is:
- **[seen]** is visible in a saved screenshot.
- **[doc]** comes from official docs or release notes.
- **[est]** is my estimate from screenshots or platform norms. Measure it against a real device before you lock it.

Point values assume a 393pt-wide iPhone (15/16/17 Pro). App Store marketing frames are scaled, so dimensions are estimates.

Apps covered: ChatGPT (6448311069), Claude (6473753684), Grok (6670324846), Cursor (6767085653), T3 Code (6787819824), Happy, a Codex/Claude Code client (6748571505), and Gemini (6477489729, for comparison).

---

## 0. Global design language (shared by all three chat apps)

| Token | Recommendation | Basis |
|---|---|---|
| Background | Light: pure `systemBackground` (#FFFFFF). Dark: #000 (Grok) or #0D0D0D to #121212 (ChatGPT/Claude). Claude light uses a warm off-white (#FAF9F5-ish). | [seen] |
| Body text | SF Pro Text 17pt Regular, line height about 1.35. Claude uses a serif for assistant prose (Anthropic's "Tiempos"-like serif); for cmux, keep SF Pro and use SF Mono for code. | [seen] |
| Secondary text | 15pt Regular `secondaryLabel` | [est] |
| Section headers in lists | 13pt Semibold `secondaryLabel` ("Today", "Yesterday", "Pinned") | [seen] ChatGPT sidebar, Cursor |
| Accent | Near-monochrome. Black or white primary buttons; color only for state: green = passed/connected, orange = approval needed, red = failed/deletions. Claude adds a brand terracotta (#D97757) only on the new-chat FAB. | [seen] |
| Corner radii | Composer 24 to 28pt (capsule when one line). Cards 16 to 20pt. User bubble 18 to 20pt. Buttons 12pt or capsule. | [est] |
| Glass | Floating nav buttons (hamburger, new chat, ellipsis) are circular 44pt `.glassEffect()` buttons, not a classic nav bar. The composer floats as a glass capsule above content, and content scrolls under it with a scroll-edge blur. | [seen] Claude/Cursor/T3 screenshots; iOS 26 standard |
| Haptics | Light impact on send. Soft impact when the drawer snaps. Success notification when an agent finishes or approval resolves. | [est] |

**Recommendation:** use system materials and the standard `ToolbarItem` glass buttons. Don't hand-roll blur. Use the ChatGPT/Claude monochrome palette, and reserve color for agent state (the Cursor/T3 convention).

---

## 1. Welcome and authentication

### What each app does
- **ChatGPT** [seen `chatgpt/mobbin-welcome-get-started.png`, `screensdesign-01-...png`]
  - Full-bleed animated color field (orange or blue) with the "ChatGPT ●" wordmark centered. On the newer version it reads "Let's go ●" on white, and the dot pulses or morphs.
  - A bottom sheet with a large top radius (about 38pt, matching the device corner) holds 4 stacked full-width buttons, each about 50pt tall with 8pt gaps:
    1. "Continue with Apple": white fill, black text, Apple logo.
    2. "Continue with Google": dark grey fill, multicolor G.
    3. "Sign up" / "Sign up with email": dark grey, envelope icon.
    4. "Log in": outlined, transparent.
  - Labels are 17pt Semibold.
  - After auth comes a "Welcome to ChatGPT" interstitial [seen `mobbin-welcome-message-continue.png`]: 34pt Bold large title, 17pt secondary body, three rows of icon + 17pt Semibold title + 15pt body, and a full-width "Continue" button pinned at the bottom.
- **Claude** [seen `claude/screensdesign-01-splash-logo.png`, `screensdesign-08-welcome-google-apple-email.png`]
  - Splash: terracotta spark logo + "Claude" wordmark centered, "BY ANTHROP\C" at the bottom.
  - Welcome: logo at top, a hand-drawn line illustration, then the headline "The AI for problem solvers" in about 28pt serif.
  - Below that: "Continue with Google" (black capsule), "Continue with Apple" (black capsule), an email text field with an inline circular arrow submit button (about 36pt) at its trailing edge, and 11pt legal text.
  - Email sign-in sends a magic link. A verification code is shown only when the link is opened on another device, and you type that code on the requesting device [doc support.claude.com/en/articles/13189465].
  - A soft paywall follows ("Choose a plan", Free/Pro/Max segmented control, "Stay on Free" secondary button) [seen `screensdesign-02`].
- **Grok**: SSO with X, Apple, Google, and email. I found no public screenshots of its auth flow; screensdesign lacks one.

### Spec for cmux (copy the ChatGPT structure with Claude's email row)
1. **Splash/hero:** full-screen `systemBackground`. Centered cmux mark (64pt) plus a 34pt Bold wordmark.
   - A one-line tagline below in 17pt `secondaryLabel`, e.g. "Your Mac's terminals and agents, in your pocket".
   - Animation: the tagline uses a shimmer, i.e. a gradient mask sweeping left to right in 1.6s and repeating every 3s. Apply it with `.mask` over a `LinearGradient` driven by `phaseAnimator`. ChatGPT's pulsing dot is a fit for a "connecting" indicator.
2. **Auth sheet:** a non-dismissable bottom panel, glass or `secondarySystemBackground`, with a 38pt top radius and 20pt horizontal insets. Stack:
   - `SignInWithAppleButton(.continue)`, 50pt tall, capsule.
   - "Continue with Google": 50pt, `tertiarySystemFill` background, Google G asset.
   - "Continue with email": 50pt, `envelope.fill`.
   - Then 12pt legal text, with links to Terms and Privacy.
   - 10pt between buttons, 34pt bottom padding above the home indicator.
   - Entry: the sheet rises with `.spring(response: 0.45, dampingFraction: 0.85)` about 0.3s after the hero appears, and the hero mark moves up 40pt as it does.
3. **Email entry:** push a screen with a 28pt Bold title "What's your email?", a 17pt subtitle, and a single 52pt-tall rounded (14pt) field with `.textContentType(.emailAddress)` and the keyboard up immediately. "Continue" is a full-width 50pt button pinned above the keyboard (`safeAreaInset(edge: .bottom)`), disabled until the email is valid.
4. **Code entry:**
   - Title: 28pt Bold "Check your email". Subtitle: "We sent a 6-digit code to name@x.com", with the email shown in semibold.
   - Six boxes, each 48×56pt with a 12pt radius and 8pt gaps, in SF Mono or SF Pro Rounded 28pt Semibold. They are backed by one hidden `TextField` with `.textContentType(.oneTimeCode)` so iOS autofill works.
   - Box states: the active box gets a 2pt `label`-colored border. A wrong code shakes the row (3 oscillations, 0.4s) and turns the borders red.
   - Below: "Resend code (0:30)", then an "Open Mail" capsule.
   - Auto-submit when the 6th digit arrives. Show a success checkmark morph (`symbolEffect(.bounce)`), then crossfade to the app.
5. **Post-auth:** one ChatGPT-style "Welcome" screen with 3 icon rows, adapted to cmux:
   - `macbook.and.iphone` "Pair your Mac"
   - `lock.shield` "End-to-end encrypted"
   - `bell.badge` "Get notified when agents need you"
   - Then pairing by QR code, which is how Codex Remote, Claude Remote Control, and T3 pair [doc].

---

## 2. Side drawer (hamburger)

### Observed
- **ChatGPT** [seen `chatgpt/mobbin-sidebar-recent-chats-search.png`]
  - The drawer is about 85% of screen width (about 330pt) and **pushes** the chat to the right; a sliver of the chat stays visible and dimmed on the right.
  - Top: a search field, 36pt tall, `magnifyingglass` icon, "Search" placeholder.
  - Then fixed rows: ChatGPT, Explore GPTs, Library. Each row is 44pt with a 20pt icon and 17pt Medium text. The selected row gets a `secondarySystemFill` rounded (10pt) highlight.
  - Then date groups ("Today", "Yesterday", 13pt secondary) with chat titles at 17pt Regular, one line, truncated.
  - Bottom: a pinned profile row with a 28pt avatar circle, name in 17pt Semibold, and a trailing `ellipsis`.
  - March 2026 change [doc help.openai.com release notes]: plan surfaces (Images, Codex, Pulse, Apps) moved into a **horizontal chip bar above chats/projects**.
  - New chat is a `square.and.pencil` button in the chat nav bar, not in the drawer.
- **Claude** (pre-redesign; a Liquid Glass navigation overhaul was reported in Sept 2026 [cryptobriefing])
  - Same push drawer.
  - Fixed items: Chats, Projects, Artifacts, **Code**. Claude Code sessions live in the Code tab [doc code.claude.com/docs/en/mobile].
  - Then a Recents list and a profile row with the plan name at the bottom.
  - New chat is a terracotta circular FAB (`plus.bubble`) at the top right of the chat screen [seen `claude/appstore-iphone-07-code-review.png`].
- **Grok:** a hamburger at the top left [seen], with conversation history and search. Its nav center holds an **Ask / Imagine / Build** segmented capsule instead of a model title [seen `grok/appstore-iphone-0*.png`].
- **Cursor:** no drawer. It uses a root list "All Workspaces" with back, search, and filter buttons [seen].

### Spec for cmux (copy ChatGPT's push drawer, with a Cursor-style grouped list inside)
- **Width:** `min(screenWidth - 64, 340)`. The chat view translates right by the drawer width.
- **Dimming:** an overlay of `Color.black.opacity(0.0 → 0.25)` interpolated with drag progress. Tapping the visible strip closes the drawer.
- **Optional depth:** scale the chat to 0.96 with a 12pt corner radius as it slides. This is subtle; ChatGPT does not scale, it slides flat.
- **Gestures:**
  - Pan from anywhere on the chat with a horizontal-dominant drag (not edge-only, like ChatGPT). Disable this while horizontally scrollable code blocks are under the finger.
  - When the drawer is open, a left swipe closes it.
  - Snap open when progress > 0.4 or velocity > 500pt/s. Animate with `.spring(response: 0.35, dampingFraction: 0.86)`.
  - Light haptic when the drawer snaps open.
- **Contents, top to bottom:**
  1. A header row: a glass search field (36pt, `magnifyingglass`, "Search sessions") plus a trailing 36pt `square.and.pencil` new-session button.
  2. A horizontal chip bar, matching ChatGPT 2026: **Macs** (`desktopcomputer`), **Agents**, **Terminals** (`terminal`), **Projects** (`folder`). Chips are 32pt tall capsules with 13pt Medium text.
  3. A grouped list:
     - **Needs attention** (orange dot), Pinned, Today, Yesterday, Previous 7 days, then older months.
     - Each row is 52pt tall:
       - Line 1: 17pt Regular title.
       - Line 2: 13pt secondary text with the Mac name, branch, and status. Cursor shows "acme · ✓ Passed · +8 −23" [seen].
       - A leading 8pt status dot: blue = working, green = done, orange = needs approval, grey = idle.
  4. A pinned bottom profile row (56pt): a 32pt avatar, name in 17pt Semibold, the connected Mac count in 13pt secondary, and a trailing `gearshape`.
- **Long-press on a row** opens a context menu: Rename (`pencil`), Pin (`pin`), Archive (`archivebox`), Delete (`trash`, destructive).

---

## 3. Chat/session list (root, when not using a drawer)

The best references are **T3 Code "Every agent, every machine, one inbox"** and **Claude Code tab** [seen `t3code/appstore-iphone-01-01-sessions.png`, `claude/appstore-iphone-07-code-review.png`].

- **T3:** a plain list.
  - Each row has three lines:
    - A provider/project label at 13pt with a small icon ("T3 Code", "React", "Linux").
    - The task title at 17pt Semibold.
    - The branch and machine ("feat/remote-command-center · Moonbase Terminal") at 13pt mono-ish secondary.
  - Trailing status text in color: "Working" in blue, "Approval" in orange, a relative time ("9m", "40m") in grey.
  - Sections: active, "Unsent" ("Sends on reconnect"), then collapsed "Snoozed (2)" and "Settled (3)".
  - Below the list, the provider logos appear ("Works with the agents you already use").
- **Claude Code tab:** filter chips "All 300 · Blocked 12 · In progress 3 · Done", each a capsule with its count.
  - Sessions are cards with a leading 36pt rounded status tile:
    - spinner = running
    - `hand.raised` on a yellow tile = blocked/needs approval
    - `arrow.triangle.pull` on a green tile = PR
  - Each card shows the title, repo (`cloud` icon + "claudeai/web-app"), and a relative time.
  - A blocked card expands inline to show the agent's question and a full-width **Approve** button. Approvals happen without opening the session.
- **Cursor:** "All Workspaces" with Pinned, Today, and per-repo sections. Rows have a status glyph, the title, and "repo · ✓ Passed · +800 −150". The composer is pinned at the bottom of the list ("Plan, ask, build…") so you can start an agent from the root [seen].

**Spec for cmux:**
- Use Claude's **filter chips + inline-approval cards** for the "needs you" path.
- Use T3's **dense 3-line rows** for everything else.
- Pin a Cursor-style composer at the bottom of the root list to start a new agent on the selected Mac.
- Section order: Needs attention > Running > Recent > Settled (collapsed).

---

## 4. Chat screen

### Navigation bar
- **ChatGPT:** leading hamburger, centered model/plan title ("ChatGPT" or "Get Plus +"), trailing `square.and.pencil` + `ellipsis` [seen].
- **Claude:** glass circle hamburger, centered model picker "Sonnet 4.5 ⌄", terracotta new-chat FAB [seen `claude/mobbin-message-actions-toolbar.png`].
- **Grok:** segmented mode switch in the center [seen].
- **T3/Happy:** back chevron, then two lines: the title (17pt Semibold, truncated) and a subtitle ("T3 Code · Moonbase Terminal" or "~/Develop/slopus/happy", 12pt secondary). Trailing glass capsule group holds `terminal`, `folder`, `arrow.triangle.branch` [seen `t3code/appstore-iphone-03-03-chat.png`].
- **Spec for cmux:** use the T3 layout.
  - Leading: a glass back/hamburger button.
  - Center: two lines. The title (17pt Semibold) and a tappable subtitle with the Mac, path, and model (`chevron.down`). Tapping the subtitle opens a menu to switch model or agent, like Claude's picker.
  - Trailing: a glass capsule with 3 icon buttons (`terminal`, `folder`, `arrow.triangle.branch` for diff/git), each 44pt.
  - Use `.toolbar` with `ToolbarItemGroup` so iOS 26 groups them into one glass capsule automatically.

### Empty state
- **ChatGPT:** a large centered wordmark, plus horizontally scrolling suggestion cards above the composer. Each card is 2 lines (15pt Semibold title + 15pt secondary) with a 16pt radius and `secondarySystemBackground` [seen `mobbin-chat-empty-state-suggested-prompts.png`].
- **Claude:** a centered serif greeting ("How can I help you this evening?").
- **Spec for cmux:** center the Mac name and a status pill. Then show 3 to 4 suggestion chips above the composer: "Run tests", "Summarize last session", "Open terminal", "Fix failing CI".

### Scroll behavior
- On send, the new user message animates to the top of the viewport and the reply streams below it. ChatGPT and Claude both do this, using `.defaultScrollAnchor(.top)` for the new turn.
- A floating 36pt glass `arrow.down` button appears when you are more than a screen from the bottom [seen in Claude screenshot].
- T3 release notes explicitly fixed "thread would scroll back up to the top un-intuitively" [doc]. Never auto-jump while the user is reading.

---

## 5. Composer

| App | Layout [seen] |
|---|---|
| ChatGPT | One floating rounded rect (about 52pt when one line, radius about 26pt). "Ask anything" placeholder on line 1. Line 2 has `plus` at the leading edge, then `slider.horizontal.3` (tools), and at the trailing edge `mic` plus a filled black circle with a waveform (voice mode). The waveform button **becomes an `arrow.up` send** circle once text exists, and **a `stop.fill` square** while streaming. |
| Claude | "Reply to Claude" placeholder. Line 2 has `plus` and a "Sonnet 5 Medium" model chip, then `mic` and a black waveform circle. The send button is a terracotta `arrow.up` circle when text exists. |
| Grok | "Ask anything…" on line 1. Line 2 has `plus` and an "Auto ⌄" / "Expert ⌄" mode chip, then a white capsule **"Speak"** button with a waveform icon. It turns into a "Stop" capsule while generating. |
| Cursor | "Plan, ask, build…" / "Follow up…". Leading `plus` and a model chip ("Composer 2.5 ⌄"), trailing `mic`. While dictating it shows a timer chip "0:23" with a live waveform. A "Continue in: Remote Control / Local" menu sits under the field [seen `cursor/web-changelog-remote-control.png`]. |
| T3 Code | A single-line capsule: `plus` + "Ask the repo agent, or run a command" + `mic` + a light-blue `arrow.up` circle (disabled tint until text). Above the keyboard, terminal mode shows a key bar: esc, tab, ctrl, arrows, `|`, `~` [seen `t3code/appstore-iphone-04-04-terminal.png`]. |
| Happy | The field shows status underneath: "master · 14 files +18 −18", plus a gear and an info button [seen]. |

**Spec for cmux:**
- **Container:** a glass rounded rect with 16pt horizontal margins and 8pt above the keyboard or home indicator. Min height 52pt; it grows to 6 lines (about 160pt), then scrolls internally. Radius 26pt, or 22pt once it is multi-line.
- **Layout:**
  - Row 1 is a `TextField(axis: .vertical)`, 17pt.
  - Row 2 is the toolbar, 36pt:
    - Leading: `plus` (attach: photo, file, screenshot).
    - Then the agent/model chip, a capsule of 13pt Medium text + `chevron.down`, e.g. "Claude Code · Opus".
    - Then a permission-mode chip (`hand.raised`: "Ask", "Accept edits", "Plan", "Auto"). This mirrors Claude's mobile modes [doc].
    - Trailing: `mic` (dictation), then a 36pt primary circle.
- **Primary button morph:**
  1. Empty: `waveform` (voice).
  2. With text: `arrow.up`, label-colored fill.
  3. Streaming: `stop.fill`.
  - Use `contentTransition(.symbolEffect(.replace))` and a 0.2s spring for each change.
- **Terminal context:** swap in a T3-style accessory key bar (`esc tab ctrl ↑ ↓ ← → | ~`), 44pt tall, with glass key caps.
- **Below the field:** a single 12pt secondary status line, combining Happy and Cursor: "● online · main · 3 files +42 −7 · 54% context left".
- **Keyboard:** `.scrollDismissesKeyboard(.interactively)`. The composer rides the keyboard via the safe area. On send, keep the keyboard up.

---

## 6. Message types

| Type | Spec | Reference |
|---|---|---|
| User message | Right-aligned bubble with max width 80% and an 18pt radius. Fill: `secondarySystemFill` (light grey #F2F2F2 / dark #2A2A2A). 17pt text, padding 14h × 10v. T3 adds a timestamp and copy icon below it in 12pt grey. | ChatGPT, Claude, T3 [seen] |
| Assistant text | Full width, no bubble, 16pt side insets. Markdown: H1 22pt Bold, H2 20pt Semibold, H3 17pt Semibold. Bullets with a 20pt hanging indent. 12pt paragraph spacing. Bold inline. Links underlined in the accent color. | ChatGPT `screensdesign-03`, Claude |
| Streaming | Text appears token by token with a soft fade-in per chunk (opacity 0 to 1 over 0.15s). ChatGPT shows a pulsing ● cursor at the end while streaming. Do not animate layout height per token; batch at about 30 to 60Hz. | [est] |
| Thinking/reasoning | Claude: a collapsed one-line row with a `clock`/sparkle icon and a 15pt secondary summary ("Prioritized conciseness and mobile-friendly c…") plus a trailing `chevron.right`. T3: "Worked for 2m ›". Tapping expands to a grey, smaller (15pt) transcript. While live, shimmer the label ("Thinking…") with the same gradient-mask shimmer. | Claude `screensdesign-03`, T3 `03-chat` [seen] |
| Tool-call rows | Happy: stacked 44pt rows, each a `secondarySystemBackground` 10pt-radius card with an icon (`eye` = read, `doc.badge.plus`/`pencil` = edit, `terminal` = bash) and a 15pt mono file path. Edits expand into an inline mini-diff (red/green line backgrounds, 13pt SF Mono). For cmux: collapse consecutive reads into "Read 4 files ›", give each row a trailing status (spinner / `checkmark` / `xmark`), and let a tap expand it to show the output. | Happy `ios-screenshot-1` [seen] |
| Code blocks | 13 to 14pt SF Mono on `secondarySystemBackground`, 12pt radius. A header bar shows the language label at the leading edge and a `doc.on.doc` "Copy" button at the trailing edge, with a checkmark confirmation for 1.5s. Code scrolls horizontally with no wrap. | ChatGPT/Claude norm [est] |
| Rich cards | Claude: map/place card, file/artifact card ("All About Minnie · Presentation · PPTX" with a doc icon), flashcards. Cursor: video demo card with play button, "Walkthrough" header. For cmux: a **"Port 5173 is live · forwarded" card with an "Open ↗" capsule** (from T3), a test result card ("612 passed · 2 warnings · 0 failed"), and screenshot cards. | [seen] |
| Action row (after assistant turn) | Icons at 18pt in a 32pt hit area, 16pt gaps, `secondaryLabel`: `doc.on.doc` copy, `speaker.wave.2` read aloud, `hand.thumbsup`, `hand.thumbsdown`, `arrow.clockwise` regenerate, `square.and.arrow.up` share. Shown only on the latest turn, or always (ChatGPT shows it on every turn). Claude adds "Claude can make mistakes" in 12pt. Feedback shows a top toast ("Thank you for your feedback!") [seen `chatgpt/screensdesign-08`]. | ChatGPT, Claude `mobbin-message-actions-toolbar` [seen] |
| Long-press | On a message: a context menu with a lifted preview (system `.contextMenu` with preview) offering Copy, Select Text, Edit (user messages), Regenerate, Share, Report. cmux: add "Copy as Markdown" and "Open in terminal" for command outputs. | [est, standard] |

---

## 7. Coding agent session screens (most important for cmux)

### Observed patterns
- **T3 Code** [seen]
  - **Environments** screen: a list of machines, each a 2-line row (name + URL, green "Connected" / grey "Available · Relay online") with a trailing toggle. Separate sections for "T3 Connect" managed hosts and "GitHub routing".
  - **Terminal** screen: a full-width, real ANSI-colored terminal on a white background (in light mode), 12pt mono, with a key bar above the keyboard.
  - **Diff** screen ("Dirty worktree +15 −2"):
    - Each file has a header (path in mono, "−0 +10", and a review checkbox) and collapses.
    - Unified diff with line numbers. Additions on a green tint (#E6F7EA), deletions on a red tint (#FDECEC).
    - A bottom sticky card: "Ready to merge · 2 files +15 −2 · 612 tests passed", then [Request changes] (outlined) and [Approve & merge] (black fill).
  - **Live Activity:** "3 active agents · 2 need attention", then a per-agent status list (Approval / Input / Working / Done).
- **Cursor** [seen]
  - The session screen shows the user prompt bubble, then "Finished 5m" and a "Walkthrough" video card, then a prose summary.
  - The bottom bar holds "Review +2 −2" and "Squash & Merge" capsules above the composer.
  - The PR screen: title (22pt Semibold), chips "Open · +2 −2 · 1 File · 1 Commit", a "Ready to Merge" card (avatars, "All Required Checks Passed", a black full-width **Squash & Merge** button), a "Deployments" list with checkmarks and times, then "Demos".
  - Live Activity and lock screen notification: "Finished · Update quick action pills… · +80 −230 · 3 Files · [Review]", plus a stack "5 Active".
  - Annotate-screenshot mode: dark editor with numbered pins and per-pin comments.
- **Claude Code (Code tab)** [doc+seen]
  - Repo + branch picker, then a task prompt.
  - Sessions show progress, questions, and approvals.
  - Permission modes are Manual / Accept edits / Plan / Auto; Bypass is not available on mobile.
  - Push notifications fire for "finished" and "needs decision".
  - Inline Approve button on the list card.
- **Codex in ChatGPT** [doc]
  - May 2026 Remote: QR pairing with the ChatGPT desktop app over an E2E relay.
  - Active threads per host; swipe between hosts.
  - Approve commands with the same gates as the desktop app.
  - Syntax-highlighted diffs, test results, screenshots, `/model` switching.
  - Earlier cloud tasks had "View diff / Ask for changes / Push PR" and a Live Activity.
  - Known pitfall (#24270): the permission picker said "Full access" but new threads started restricted. **Show the effective mode, not just the selection.**
- **Happy** [seen]
  - The session list splits ACTIVE SESSIONS (with a green "online" dot) from PREVIOUS SESSIONS ("last seen 1 day ago").
  - Each row shows an identicon avatar, the title, and the path.
  - Full-screen diff with a file path header and a green check.

### cmux spec
1. **Session screen** = the chat screen (§4) plus three things:
   - A **status strip** under the nav bar, 32pt, glass. It shows a status dot + "Working · 2m 14s", the current tool ("Running `pnpm test`"), and a trailing "Stop" capsule.
   - Tool-call rows (§6).
   - A **sticky bottom review bar** (Cursor) when the agent finishes with changes: "+42 −7 · 3 files" [Review] [Commit/PR].
2. **Approval card** (the most important interaction):
   - An inline card in the transcript and also pinned above the composer.
   - The card is `secondarySystemBackground` with an orange 2pt leading accent and a 16pt radius. Inside:
     - A `hand.raised.fill` orange icon + 15pt Semibold "Claude Code wants to run".
     - The command in a 13pt mono block.
     - The cwd in 12pt secondary.
     - A risk label.
   - Buttons in a row, 44pt each:
     - [Deny] (outlined)
     - [Allow once] (black fill)
     - an overflow `ellipsis` holding "Always allow `pnpm *`" and "Switch to Accept edits".
   - The same actions appear as notification actions and in the Live Activity (Claude/Cursor/Moshi pattern).
   - Resolving it collapses the card to a 1-line "✓ Allowed `pnpm test`" row with a 0.25s spring.
3. **Diff viewer:** copy T3.
   - The file list header shows "N files +A −D".
   - Each file is a collapsible section with a sticky header: mono path truncated in the middle, +/− counts, and a "Viewed" checkbox.
   - Unified diff at 12pt SF Mono with 2-column line numbers and green/red tints. Pinch or toggle to wrap.
   - Swipe left/right moves between files.
   - Bottom bar: [Request changes] [Approve & commit].
4. **Terminal:** a full-screen Ghostty-rendered surface. Accessory key bar as in T3. A "Port 5173 is live" toast card with "Open ↗" when the agent starts a server.
5. **Machines (Environments):** a T3-style list.
   - Each Mac row shows its name, host, a connection state dot (green Connected / grey Offline · last seen), and the agent count.
   - A trailing `chevron.right` opens the Mac's workspaces.
   - "+" adds a Mac by QR.
6. **Live Activity / Dynamic Island:**
   - Compact: the cmux mark + a count badge of agents needing attention.
   - Expanded: up to 3 agent rows (title, status word in its color), plus Approve/Open actions.
   - Copy T3's "3 active agents · 2 need attention" header.

---

## 8. Settings and profile

- **Claude** [seen `claude/screensdesign-07-settings-dark-appearance.png`, `06-connectors`]
  - Presented as a sheet, with an `xmark` glass button at the top left.
  - Grouped rows with 20pt leading icons, chevrons, and 17pt labels: Notifications, Time & focus, Privacy, Shared links. Then an "App" section: Capabilities, Connectors, Permissions, Voice, Haptic feedback (toggle).
  - Appearance is shown as **three preview tiles** (Light / Dark / System) about 100×64pt; the selected tile gets a 2pt accent border.
  - "Log out" is a red row at the bottom.
- **ChatGPT:** opened from the profile row. Account, Personalization, Data controls, Voice, and so on as an inset grouped list.
- **cmux spec:** an inset grouped `Form` in a sheet from the drawer profile row. Sections:
  - **Account**: avatar, email, plan.
  - **Macs**: paired devices, "Pair new Mac" (`qrcode.viewfinder`).
  - **Agents**: default agent/model, default permission mode.
  - **Notifications**: finished / needs approval / failed toggles, Live Activities.
  - **Appearance**: Claude-style 3 tiles, terminal font size, theme.
  - **Privacy & Security**: Face ID lock, E2E key fingerprint.
  - **About**.
  - **Sign out**: destructive.

---

## 9. Motion cheat sheet

| Interaction | Animation |
|---|---|
| Drawer | Interactive pan, `.spring(response 0.35, damping 0.86)`. Dim 0 to 25%. Content translates (ChatGPT push). |
| Send | The user bubble scales from 0.96 and fades in from the composer position (0.25s spring). The scroll anchors the new turn to the top. |
| Send/stop morph | `symbolEffect(.replace)`, 0.2s. |
| Thinking/working label | Gradient-mask shimmer, 1.6s sweep, repeating. |
| Approval resolved | Card height collapse + checkmark `symbolEffect(.bounce)`, plus a success haptic. |
| Auth sheet | Rises 0.3s after the hero, spring 0.45/0.85. The hero shifts up. |
| Code copy | The icon swaps to `checkmark` for 1.5s. |
| Tool row expand | `DisclosureGroup`-style height animation, 0.25s easeInOut. The chevron rotates 90°. |

---

## 10. What to copy from where (summary)

| Area | Copy | Why |
|---|---|---|
| Welcome/auth | ChatGPT's hero + bottom sheet of 4 stacked buttons. Claude's inline email field with an arrow button. OTP boxes with `.oneTimeCode`. | The most familiar layout. Apple sits first, as App Review expects. |
| Drawer | ChatGPT push drawer + 2026 chip bar | Fast and gesture-rich, and it scales to many sessions. |
| Session list | Claude Code filter chips + inline Approve cards. T3 3-line rows and sections. | Approvals without opening the session; dense machine and branch context. |
| Chat nav | T3 two-line title + glass trailing tool group (terminal, files, git) | It fits a developer tool, and iOS 26 groups toolbar items into glass automatically. |
| Composer | ChatGPT morphing primary button. Cursor/Claude model chip. T3 terminal key bar. Happy status line. | Covers both chat and terminal use. |
| Messages | ChatGPT/Claude: grey right bubbles, full-width assistant markdown. Claude collapsible thinking. Happy tool rows. | Industry norm. |
| Diff/review | T3 diff + Cursor "Ready to merge" card | The clearest mobile review flow. |
| Notifications | Cursor/T3 Live Activities with actions | Agents are long-running. |
| Settings | Claude's grouped sheet + appearance tiles | Clean, and native-feeling. |

### Notable differences between apps
- **Typography:** Claude uses a serif for assistant text and headlines. ChatGPT and Grok use sans-serif. Grok is dark-first (pure black).
- **New chat:** ChatGPT puts it in the nav bar as a pencil icon. Claude uses a colored FAB. Grok and Cursor put the compose button in the nav.
- **Model picker:** Claude puts it in the nav title. Grok replaces it with mode tabs. Cursor and Claude Code put a model chip in the composer.
- **Voice:** ChatGPT and Claude use a waveform circle. Grok uses a labeled "Speak" pill, which is the most discoverable.
- **Coding apps:** Cursor is cloud and PR-centric (merge, deployments, demo videos). T3, Happy, Claude Remote Control, and Codex Remote are host-centric (machines, terminal, approvals). **cmux matches the host-centric model.**

## Sources
- App Store listings: https://apps.apple.com/us/app/id6448311069 (ChatGPT), https://apps.apple.com/us/app/id6473753684 (Claude), https://apps.apple.com/us/app/id6670324846 (Grok), https://apps.apple.com/us/app/cursor/id6767085653, https://apps.apple.com/us/app/id6787819824 (T3 Code), https://apps.apple.com/us/app/id6748571505 (Happy), https://apps.apple.com/us/app/id6477489729 (Gemini). Screenshots via the iTunes lookup API.
- Mobbin screens: https://mobbin.com/explore/screens/f0f5c405-c0b1-4642-8737-d2006812a442 , /52bab164-8fc0-4def-be5b-e7153f3dd49a , /c176ae9f-5a25-45b6-acda-5620364105df , /5e55dde4-61e8-4f5d-95c0-7a9da129ec91 , /f08ad45c-a3db-44f6-8cab-d42e1312f25d , /318a2e93-28f6-4e28-93bc-19b4518486d7
- screensdesign: https://screensdesign.com/showcase/claude-by-anthropic , https://screensdesign.com/showcase/chatgpt
- Claude Code on mobile docs: https://code.claude.com/docs/en/mobile
- Claude login help: https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account
- Claude iOS Liquid Glass redesign report: https://cryptobriefing.com/claude-liquid-glass-ios-redesign/
- ChatGPT release notes (Mar 26, 2026 mobile sidebar chip bar): https://help.openai.com/en/articles/6825453-chatgpt-release-notes
- Codex mobile: https://openai.com/index/work-with-codex-from-anywhere/ , https://x.com/OpenAIDevs/status/1924601527898951914 , https://github.com/openai/codex/issues/24270 , https://www.testingcatalog.com/openai-brings-codex-to-chatgpt-mobile-app-for-ios-and-android/
- Cursor iOS: https://cursor.com/changelog/ios-mobile-app , https://cursor.com/mobile , https://x.com/cursor_ai/status/2107618653701296162
- T3 Code: https://t3.codes/
- Third-party Claude Code mobile clients: https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/ , https://getmoshi.app/articles/run-claude-code-from-phone
