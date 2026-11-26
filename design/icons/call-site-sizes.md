# Icon call-site sizes

This is a measured census of every `<Icon>` call site in `webviews/src`: the size each one is drawn at, the row it sits in, and the space around it. The Mac call sites in `Packages/macOS/CmuxNext` are listed at the end, without changes. It follows the icon redraw in #53295, which made `cloud` and `cloud.synced` larger.

Measured on `feat-cmux-next` at `b4da8b7e6155`, 2026-11-24. Nobody has seen these rows rendered for this census. Every number below comes from source: the `size` prop, the CSS that styles the svg or its slot, and the type tokens.

## How to read the numbers

- **Drawn** is the size the browser lays the svg out at. It usually equals the `size` prop. When a CSS rule sets the svg's width, the CSS wins; for example, `.ui-btn :where(svg)` makes it 16.
- **Row crop** marks `row` icons. They crop the viewBox to `2.5 2.5 19 19`, so their ink is about 15/19 to 18/19 of the box. A plain icon's ink is about 0.625 to 0.75 of the box.
- **Font** and **Line** are the row's text size and line height, in px, from `schemas/type-scale`:
  - caption 11/14
  - detail 12/16
  - body 13/18
  - field 14/18
  - title 15/20
  - the conversation text is 14/22.75

  `inh.` means the site inherits its type from a parent that the static pass could not resolve.
- **Slot** is the square the icon sits in.
  - `line` means the slot is the text's line box.
  - `box` and `button` mean a fixed box or an icon-only button.
  - `menu*` means the menu-metrics icon column.
- **Box pad/side** is (slot − drawn) / 2. **Ink pad/side** is (slot − ink) / 2, using the glyph's 18-unit live area.

## Does each family follow the square-slot rule?

The rule says an icon sits in a square slot as tall as its row's line, centred, with the gap token beside it.

| Family | Sites | Drawn sizes | Slot = line height | Box pad/side (min, median, max) | Ink pad/side (median) | Verdict |
|---|---|---|---|---|---|---|
| Inline marks (pills, chips, lines) | 51 | 12 ×12, 14 ×26, 16 ×13 | 31 of 31 measured | −1, 1, 3.4 | 2.75 | Follows the rule. Drawn = line − 2 on this type scale: caption 14 → 12, detail 16 → 14, body 18 → 16. Kept. |
| Leading row icons | 19 | 12 ×5, 14 ×7, 16 ×6, 20 ×1 | 5 line slots, plus fixed boxes or columns 2 px wider than the icon | 0, 1, 2 | 2.3 | Follows the rule. The boxes are the row's line height or the 16/20 icon column. Kept. |
| Disclosure and back chevrons | 38 | 12 ×37, 16 ×1 | 11 of 21 measured sit in the line; the other 10 sit in their own 16 box | 0, 2, 4 | 3.5 | Follows the rule. A 12 chevron in a 16 line is on the scale (12 is the scale's chevron size). Kept. |
| Menu row icons | 9 | 12 ×1, 14 ×8 | Slot is the menu icon column `--cmux-menu-icon-size` 14 (menu-metrics, AppKit's own) | 0, 1, 2 | 2.5 | Follows the menu rule (14 box). Kept. |
| Close, stop and remove marks | 17 | 12 ×12, 14 ×4, 20 ×1 | No. They sit in 18 to 28 px hit targets by design | 3, 5, 10 | 6.5 | Follows the button rule, not the line rule. Kept. |
| Icon-only action buttons | 19 | 12 ×3, 14 ×9, 16 ×3, 20 ×4 | No. They sit in control boxes (20 / 24 / 28 / 32) | 0, 4, 12 | 5.75 | Padding comes from the control size tokens, not from the icon. Kept. |
| Glyph in a tinted badge | 1 | 14 | 20 circle | 3 | 4.75 | A designed badge (PullRequestCard). Kept. |
| Composer glyph set | 1 (+ 5 bare svgs) | 18 | Line | 0 | 2.25 | The named exception in grid.md and iconSize.ts. Kept. |
| Artwork and empty states | 2 | 20, 28 | n/a | n/a | n/a | Artwork, not row icons. Kept. |

Of the 157 sites, 116 have a measured slot. The other 41 inherit their type from a parent that the static pass could not resolve. Most are chevrons in cards and trays. They are listed with `-` in the full table.

## Answer to "should we shrink the space outside the icon?"

No. Where an icon sits in a line of text, the space around the ink is already the normal amount: about 1 px of box per side, and 2 to 3.5 px from ink to slot edge. That comes from the line height, not from extra padding, so shrinking it would mean shrinking the line or overlapping the text.

The larger gaps are in icon-only buttons and close marks, at 4 to 12 px of box per side. They are set by the control size tokens (20 / 24 / 28 / 32), which keep the click target. Shrinking them would shrink the hit target. That is a control-size decision, not an icon-size one.

## What moved, what stayed

**No call site changed size in this PR.** Each 14 or 18 that the brief named as possible drift is on the repo's scale or a named exception, or moving it would shift the layout or split a column:

| Site(s) | Size | Kept, reason |
|---|---|---|
| Inline marks beside detail (12/16) text (26 sites) | 14 | 14 is on the scale (`design-scale.json` "inline with text", `rowIconSize(12) = 14`, grid.md) and equals line − 2. Going to 12 would make them the "dinky" Leo named; going to 16 would fill the line with no air. |
| Menu rows (8 sites) | 14 | The box is the shared menu-metrics token, matched to native NSMenu. Going to 16 would widen every menu's icon column. |
| `newtab/StageCards.tsx` folder | 14 | Shares a column with `ProjectBadge`'s `FolderMark` at 14 (ink 10.5 vs 10.7). Moving only one would split the column. |
| `offer/OfferOptions.tsx` folder, `TerminalPickersNote.tsx` | 14 | Unboxed flex items in 13/18 text. Going to 16 would push the text 2 px. |
| `chips/PullRequestCard.tsx` | 14 in 20 | A designed badge: 3 px of tint per side. |
| `needsYou/NeedsYou.tsx` tool buttons, `ComposerQueue.tsx` actions | 14 in 20 / 22 | A cluster with a chevron and a text-label sibling. Not clearly better at 16 without seeing it. |
| `backgroundTasks/BackgroundTasksPanel.tsx` delete | 14 | CSS (`.acpmux-bg__icon.ui-btn svg`) draws it at 14 whatever the prop says. |
| `newtab/RowGlyph.tsx`, `CommandGlyph.tsx` | 14 | The prop is overridden: `--nt-glyph-ink` draws them at 16 (composer) and 15.75 (popover). |
| `composerPlusMenuModel.tsx`, `SendSlotGlyph`, `arrowUpIcon`, `GitHubIcons` | 18 | The composer glyph set, the one exception grid.md names. |

## Off-scale sizes outside `<Icon>`

Listed for the record, not changed here. Each one is either in `scripts/icon-scale-baseline.tsv` or sets a CSS box rather than an icon size.

- `styles.css` `.diff-pill-button svg` 19
- `composer/dropOverlay.css` `.acpmux-drop-mark svg` 18 (drop artwork)
- `sidebar/AllChatsDesigns.css` `.acd-icon` 18 (a design gallery)
- `icon-picker/styles.css`:
  - `.icon-chevron-left` 18
  - `.icon-grid-glyph` 17
  - `.icon-mode-symbol` 18
  - `.icon-bar-symbol` 18

## Mac (Packages/macOS/CmuxNext), listed only

| Token / site | Compact | Comfortable | Notes |
|---|---|---|---|
| `MetricTunables.iconSize` | 14 | 16 | Tab, row and toolbar icons. |
| `MetricTunables.smallIconSize` | 12 | 14 | Status marks, small accessories. |
| `Metrics.tabIconSize` | 14 | 16 | The density token, or `iconSize`. Tab favicons, including the remote `cloud` symbol (`TabItem+ShellIconTheme.swift`). |
| `MenuMetrics.iconSize` | 14 | 14 | Native menu column. |
| `toolbarGlyphSize` | ≈18.3 | derived | (smallIcon − 1) / 0.6, an ink-matched toolbar glyph. |
| `statusMarkSize` | smallIcon − space1 | | |
| `sidebarGlyphInk` | tabIconSize × 11/16 | | Ink size inside the tab icon box. |
| `OverflowButton.glyphSize` | iconRowSize | | |

The remote-machine `cloud` is drawn by `TabItem+ShellIconTheme.swift`, `SidebarMapping+MachineIcon.swift`, `RemoteMachinesSidebar.swift` and `CloudPageService.swift` at these tokens. Its ink was enlarged in #53295 (20.5 × 16 in the 24 grid). The slot was left as it was.

## Open question for the design system lead

HQ decision D1 (`docs/design/design-system-decisions/D-icons-buttons-accent-motion-keyhints.md`) sets the scale to 12/16/20:
- it removes 14 (menus → 16, inline marks → 12)
- it moves the composer and omnibar 18 → 16

The repo has not adopted D1: `design-scale.json`, grid.md, `iconSize.ts`, `check-icon-scale.ts` and the Mac tokens all still use 14. This census measures against the repo as it stands. Adopting D1 would change about 60 web sites and the Mac tokens together, and the change to inline marks would shrink them. That should be its own decision and PR.

## Full table

| Site | Icon | Literal | Drawn | Row crop | Font px | Line px | Slot px | Slot kind | Box pad/side | Ink pad/side | Family | Where the numbers come from |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `agent-session/acpmux/FloatingChat.tsx:78` | `disclosure.expanded` | 16 | 16 |  | 12 | 16 | 16 | line | 0 | 2 | chevron | acpmux-header-tool |
| `agent-session/acpmux/backgroundTasks/BackgroundTaskCard.tsx:138` | `open ?` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx:535` | `disclosure.collapsed` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx:598` | `open ?` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx:728` | `disclosure.collapsed` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx:417` | `open ?` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx:446` | `disclosure.collapsed` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx:471` | `open ?` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx:497` | `open ?` | 12 | 12 | row | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/context/ContextScreen.tsx:251` | `open ?` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/header/HeaderNewButton.tsx:94` | `disclosure.expanded` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | acpmux-header-tool |
| `agent-session/acpmux/offer/SuggestedTasks.tsx:342` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | task row, detail sub-line (row 28) |
| `agent-session/acpmux/offer/SuggestedTasks.tsx:385` | `disclosure.collapsed` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/question/HatQuestions.tsx:288` | `disclosure.collapsed` | 12 | 12 |  | 11 | 14 | 20 | button | 4 | 5.5 | chevron | acpmux-hat-questions__pager, acpmux-hat-questions__step |
| `agent-session/acpmux/question/HatQuestions.tsx:301` | `disclosure.collapsed` | 12 | 12 |  | 11 | 14 | 20 | button | 4 | 5.5 | chevron | acpmux-hat-questions__pager, acpmux-hat-questions__step |
| `agent-session/acpmux/question/HatQuestions.tsx:444` | `disclosure.expanded` | 12 | 12 |  | 11 | 14 | 14 | line | 1 | 2.5 | chevron | acpmux-hat-questions__chip |
| `agent-session/acpmux/session-info/SessionInfoSection.tsx:109` | `disclosure.collapsed` | 12 | 12 |  | inh. | inh. | 16 | button | 2 | 3.5 | chevron | acpmux-session-info-section__icon |
| `agent-session/acpmux/session-info/SubagentScopeHeader.tsx:31` | `nav.back` | 12 | 12 |  | inh. | inh. | 20 | button | 4 | 5.5 | chevron | acpmux-session-info-icon-button |
| `agent-session/acpmux/session-info/SubagentScopeHeader.tsx:68` | `nav.back` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/session-info/SubagentScopeHeader.tsx:74` | `disclosure.collapsed` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/session-info/SubagentsSection.tsx:242` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | box | 2 | 3.5 | chevron | fold chevron, as above |
| `agent-session/acpmux/session-info/TasksSection.tsx:191` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | box | 2 | 3.5 | chevron | fold chevron, as above |
| `agent-session/acpmux/session-info/WorkflowTasks.tsx:356` | `open ?` | 12 | 12 |  | 12 | 16 | 16 | box | 2 | 3.5 | chevron | fold chevron: CSS draws a 12 box (grid-icon-box - grid-base) centred in the 16 column |
| `agent-session/acpmux/started/StartedSessionCard.tsx:59` | `disclosure.collapsed` | 12 | 12 |  | 13 | 18 | 16 | button | 2 | 3.5 | chevron | acpmux-started-row, acpmux-started-icon |
| `agent-session/acpmux/subagents/AgentsPill.tsx:110` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | agents list row, detail text |
| `agent-session/acpmux/subagents/SubagentGroup.tsx:110` | `expanded ?` | 12 | 12 |  | 11 | inh. | - | - | - | - | chevron | cv-subagents__more |
| `agent-session/acpmux/subagents/SubagentGroup.tsx:172` | `disclosure.collapsed` | 12 | 12 |  | 13 | 18 | 18 | line | 3 | 4.5 | chevron | cv-subagent |
| `agent-session/acpmux/subagents/SubagentTray.tsx:1039` | `disclosure.expanded` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/subagents/SubagentTray.tsx:1075` | `disclosure.expanded` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/subagents/TrayPullTab.tsx:151` | `disclosure.expanded` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/summary/SubagentStatusList.tsx:150` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | acpmux-summary-title |
| `agent-session/acpmux/summary/SummaryCard.tsx:295` | `card.collapsed ?` | 12 | 12 |  | inh. | inh. | - | - | - | - | chevron |  |
| `agent-session/acpmux/summary/SummaryCard.tsx:337` | `card.collapsed ?` | 12 | 12 |  | inh. | inh. | 18 | button | 3 | 4.5 | chevron | acpmux-summary-tab__close |
| `agent-session/acpmux/summary/WorkflowSummary.tsx:164` | `open ?` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | acpmux-summary-meta |
| `agent-session/acpmux/summary/WorkflowSummary.tsx:256` | `disclosure.collapsed` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | chevron | acpmux-summary-meta |
| `agent-session/acpmux/summary/WorkflowSummary.tsx:266` | `disclosure.collapsed` | 12 | 12 |  | inh. | inh. | 20 | button | 4 | 5.5 | chevron | acpmux-workflow__transcript |
| `pages/github/GitHubPage.tsx:827` | `disclosure.collapsed` | 12 | 12 |  | 11 | 14 | 14 | line | 1 | 2.5 | chevron | gh-lines |
| `pages/github/ReadinessBlock.tsx:181` | `disclosure.collapsed` | 12 | 12 |  | 11 | 18 | 18 | line | 3 | 4.5 | chevron | gh-ready-blocker |
| `agent-session/acpmux/ChiefDock.tsx:267` | `action.close` | 20 | 20 |  | 11 | 17 | 40 | button | 10 | 12.5 | close | acpmux-chief-card-queue, acpmux-chief-card-dismiss |
| `agent-session/acpmux/ComposerQueue.tsx:967` | `action.close` | 14 | 14 |  | 12 | 18 | 22 | button | 4 | 5.75 | close | acpmux-queued-action, acpmux-queued-action |
| `agent-session/acpmux/HarnessStatusCard.tsx:136` | `action.close` | 12 | 12 |  | 11 | 20 | 20 | button | 4 | 5.5 | close | acpmux-harness-status__copy-all, acpmux-harness-status__close |
| `agent-session/acpmux/aside/BtwAside.tsx:38` | `action.close` | 14 | 14 |  | inh. | inh. | 24 | button | 5 | 6.75 | close | acpmux-btw-dismiss |
| `agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx:776` | `action.stop` | 12 | 12 |  | inh. | inh. | 24 | button | 6 | 7.5 | close | acpmux-bg__stop |
| `agent-session/acpmux/context/ContextScreen.tsx:113` | `action.close` | 14 | 14 |  | inh. | inh. | 28 | button | 7 | 8.75 | close | acpmux-context-screen-close |
| `agent-session/acpmux/harnesses/HarnessesScreen.tsx:381` | `action.close` | 14 | 14 |  | inh. | inh. | 28 | button | 7 | 8.75 | close | acpmux-harnesses-close |
| `agent-session/acpmux/newtab/WidgetEditing.tsx:138` | `action.remove` | 12 | 12 |  | inh. | inh. | 24 | button | 6 | 7.5 | close | nt-widget-remove |
| `agent-session/acpmux/offer/SuggestedTasks.tsx:246` | `action.close` | 12 | 12 |  | inh. | inh. | 22 | button | 5 | 6.5 | close | acpmux-task-dismiss |
| `agent-session/acpmux/session-info/SessionInfo.tsx:303` | `action.close` | 12 | 12 |  | inh. | inh. | 20 | button | 4 | 5.5 | close | acpmux-session-info-icon-button |
| `agent-session/acpmux/session-info/SessionInfo.tsx:316` | `action.close` | 12 | 12 |  | inh. | inh. | 20 | button | 4 | 5.5 | close | acpmux-session-info-icon-button |
| `agent-session/acpmux/session-info/TasksSection.tsx:257` | `action.stop` | 12 | 12 |  | inh. | inh. | 20 | button | 4 | 5.5 | close | acpmux-session-info-icon-button |
| `agent-session/acpmux/subagents/SubagentGroup.tsx:224` | `action.stop` | 12 | 12 |  | inh. | inh. | 24 | button | 6 | 7.5 | close | cv-subagent__stop |
| `agent-session/acpmux/subagents/SubagentGroup.tsx:264` | `action.close` | 12 | 12 |  | 12 | 16 | 20 | button | 4 | 5.5 | close | cv-subagent-of__pill, cv-subagent-of__close |
| `agent-session/acpmux/summary/SummaryCard.tsx:325` | `action.close` | 12 | 12 |  | inh. | inh. | 18 | button | 3 | 4.5 | close | acpmux-summary-tab__close |
| `agent-session/acpmux/summary/SummaryCard.tsx:357` | `action.close` | 12 | 12 |  | 12 | 16 | 26 | button | 7 | 8.5 | close | acpmux-summary-card__counts, acpmux-summary-card__close |
| `agent-session/acpmux/summary/WorkflowSideTab.tsx:225` | `action.close` | 12 | 12 |  | 12 | 16 | 24 | button | 6 | 7.5 | close | acpmux-workflow-side-tab__title, acpmux-workflow-side-tab__close |
| `agent-session/acpmux/ChiefDock.tsx:258` | `link.open.newtab` | 20 | 20 |  | 11 | 17 | 44 | button | 12 | 14.5 | button | acpmux-chief-card-queue, acpmux-chief-card-action |
| `agent-session/acpmux/ChiefDock.tsx:298` | `action.edit` | 20 | 20 |  | 12 | 16 | 42 | button | 11 | 13.5 | button | 72x42 dock tool |
| `agent-session/acpmux/ChiefDock.tsx:307` | `link.open.newtab` | 20 | 20 |  | 12 | 16 | 42 | button | 11 | 13.5 | button | 72x42 dock tool |
| `agent-session/acpmux/ChiefDock.tsx:316` | `disclosure.collapsed` | 20 | 20 |  | 12 | 16 | 42 | button | 11 | 13.5 | button | 72x42 dock tool |
| `agent-session/acpmux/ComposerQueue.tsx:954` | `composer.steer` | 14 | 14 |  | 12 | 18 | 22 | button | 4 | 5.75 | button | acpmux-queued-action, acpmux-queued-action |
| `agent-session/acpmux/ComposerQueue.tsx:979` | `action.delete` | 14 | 14 |  | 12 | 18 | 22 | button | 4 | 5.75 | button | acpmux-queued-action, acpmux-queued-action |
| `agent-session/acpmux/ComposerQueue.tsx:990` | `action.more` | 14 | 14 |  | 12 | 18 | 22 | button | 4 | 5.75 | button | acpmux-queued-action, acpmux-queued-action |
| `agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx:446` | `action.delete` | 14 | 14 |  | 13 | 18 | 24 | button | 5 | 6.75 | button | acpmux-bg__title, acpmux-bg__icon |
| `agent-session/acpmux/needsYou/NeedsYou.tsx:367` | `expanded ?` | 14 | 14 |  | 12 | 16 | 20 | button | 3 | 4.75 | button | 20x20 row tool |
| `agent-session/acpmux/needsYou/NeedsYou.tsx:379` | `agent.question` | 14 | 14 |  | 12 | 16 | 20 | button | 3 | 4.75 | button | 20x20 row tool |
| `agent-session/acpmux/needsYou/NeedsYou.tsx:389` | `action.go` | 14 | 14 |  | 12 | 16 | 20 | button | 3 | 4.75 | button | 20x20 row tool |
| `agent-session/acpmux/needsYou/NeedsYou.tsx:694` | `workspace` | 12 | 12 |  | 12 | 16 | 16 | button | 2 | 3.5 | button | acpmux-needs-you-side-send, acpmux-needs-you-avatar |
| `agent-session/acpmux/newtab/AddWidgetGallery.tsx:196` | `action.add` | 12 | 12 |  | inh. | inh. | 24 | button | 6 | 7.5 | button | nt-widget-preview-add |
| `agent-session/acpmux/newtab/NewTabWidgets.tsx:175` | `action.add` | 12 | 16 |  | 13 | 18 | 24 | button | 4 | 6 | button | .ui-btn :where(svg) draws it at --ds-icon-16; the 12 literal never shows |
| `agent-session/acpmux/newtab/WidgetEditing.tsx:150` | `action.more` | 12 | 12 |  | inh. | inh. | 24 | button | 6 | 7.5 | button | nt-widget-size-button |
| `agent-session/acpmux/session-info/ChangesSection.tsx:257` | `action.more` | 14 | 14 |  | inh. | inh. | 20 | button | 3 | 4.75 | button | acpmux-session-info-icon-button |
| `agent-session/acpmux/session-info/SourcesSection.tsx:181` | `action.more` | 14 | 14 |  | inh. | inh. | 20 | button | 3 | 4.75 | button | acpmux-session-info-icon-button |
| `agent-session/acpmux/share/ShareDialog.tsx:123` | `view.general ===` | 16 | 16 |  | 12 | 16 | 28 | button | 6 | 8 | button | share-dialog__heading, share-dialog__general-mark |
| `agent-session/acpmux/subagents/AgentCard.tsx:141` | `agent.session` | 16 | 16 |  | inh. | inh. | 16 | button | 0 | 2 | button | cv-agent-card__icon |
| `agent-session/acpmux/ComposerPickers.tsx:2313` | `(computed)` | 14 | 14 |  | 13 | 18 | 18 | line | 2 | 3.75 | menu | composer picker menu row |
| `agent-session/acpmux/MentionMenu.tsx:72` | `item.kind ===` | 14 | 14 |  | 13 | 18 | 16 | menu column | 1 | 2.75 | menu | .acpmux-mention-icon column 16 wide |
| `agent-session/acpmux/QuickModelMenu.tsx:1264` | `history` | 12 | 12 |  | 11 | 14 | 14 | line | 1 | 2.5 | menu | acpmux-used-caption |
| `agent-session/acpmux/SlashMenu.tsx:176` | `match.command.icon` | 14 | 14 |  | 13 | 18 | 16 | menu column | 1 | 2.75 | menu | .acpmux-slash-icon column 16 wide |
| `agent-session/acpmux/composer/SendMenu.tsx:54` | `SEND_ICONS[choice]` | 14 | 14 |  | 13 | 18 | 18 | line | 2 | 3.75 | menu | send menu row |
| `agent-session/acpmux/header/ChatHeaderTools.tsx:945` | `row.icon` | 14 | 14 | row | 13 | 18 | 18 | line | 2 | 2.37 | menu | chat menu row, 28 high |
| `agent-session/acpmux/header/ChatHeaderTools.tsx:973` | `item.icon` | 14 | 14 |  | 13 | 18 | 14 | menu box | 0 | 1.75 | menu | .acpmux-chat-menu-image 14 wide |
| `agent-session/acpmux/header/HeaderNewButton.tsx:112` | `KIND_ICONS[kind]` | 14 | 14 |  | 13 | 18 | 18 | line | 2 | 3.75 | menu | chat menu row, 28 high |
| `kit/GlassMenu.tsx:72` | `item.icon` | 14 | 14 |  | 13 | 18 | 14 | menu box | 0 | 1.75 | menu | menu box is --cmux-menu-icon-size 14 (menu-metrics iconSize, AppKit's own) |
| `agent-session/acpmux/ActiveTeamDesigns.tsx:102` | `teamIconName(team)` | 16 | 16 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/ActiveTeamDesigns.tsx:29` | `teamIconName(team)` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/ActiveTeamDesigns.tsx:61` | `teamIconName(active)` | 14 | 14 |  | 11 | 14 | 14 | line | 0 | 1.75 | inline | atd-avatar |
| `agent-session/acpmux/ActiveTeamDesigns.tsx:80` | `teamIconName(team)` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/ChiefDock.tsx:198` | `link.open.newtab` | 14 | 14 |  | 12 | 16 | 16 | line | 1 | 2.75 | inline | empty dock line, detail text |
| `agent-session/acpmux/FloatingChat.tsx:119` | `action.pin` | 16 | 16 |  | 12 | 16 | 16 | line | 0 | 2 | inline | acpmux-header-tool |
| `agent-session/acpmux/FloatingChat.tsx:58` | `composer.mention` | 16 | 16 |  | 12 | 16 | 16 | line | 0 | 2 | inline | acpmux-header-tool |
| `agent-session/acpmux/FloatingChat.tsx:68` | `action.pin` | 16 | 16 |  | 12 | 16 | 16 | line | 0 | 2 | inline | acpmux-header-tool |
| `agent-session/acpmux/FloatingChat.tsx:87` | `link.open.newtab` | 16 | 16 |  | 12 | 16 | 16 | line | 0 | 2 | inline | acpmux-header-tool |
| `agent-session/acpmux/ModelPicker.tsx:1381` | `FORK_ICON` | 12 | 12 |  | 13 | 18 | 18 | line | 3 | 4.5 | inline | acpmux-model-short |
| `agent-session/acpmux/ModelPicker.tsx:1726` | `action.reload` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/TerminalPickersNote.tsx:39` | `terminal` | 14 | 14 | row | 13 | 18 | 18 | line | 2 | 2.37 | inline | unboxed row icon; 16 would push the label 2 px |
| `agent-session/acpmux/chips/CmuxLinkChip.tsx:302` | `CMUX_LINK_ICONS[info.kind]` | 16 | 16 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/chips/CmuxLinkChip.tsx:67` | `CMUX_LINK_ICONS[info.kind]` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/chips/ToolBadge.tsx:15` | `info.icon` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/composer/SendSlotGlyph.tsx:41` | `media.play` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/conversation/ChatFindBar.tsx:116` | `ICONS[role]` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/conversation/EditedFilesCard.tsx:211` | `link.external` | 14 | 14 |  | 12 | 16 | 16 | line | 1 | 2.75 | inline | trailing link mark beside detail text |
| `agent-session/acpmux/conversation/QueuedMessageCard.tsx:201` | `action.more` | 14 | 14 |  | 11 | 14 | 14 | line | 0 | 1.75 | inline | cv-iconbtn |
| `agent-session/acpmux/conversation/QueuedMessageCard.tsx:66` | `action.more` | 14 | 14 |  | 11 | 14 | 14 | line | 0 | 1.75 | inline | cv-iconbtn |
| `agent-session/acpmux/conversation/RepoRecoveryCard.tsx:67` | `status.check` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | cv-repo-recovery |
| `agent-session/acpmux/conversation/UnverifiedMark.tsx:55` | `checked ?` | 12 | 12 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/header/ChatHeaderStatus.tsx:44` | `status.warning` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/header/HeaderNewButton.tsx:134` | `KIND_ICONS[kind]` | 14 | 14 |  | 11 | 14.3 | 14.3 | line | 0.15 | 1.9 | inline | preview caption, line-height 1.3 |
| `agent-session/acpmux/header/LiveTreePill.tsx:48` | `git.worktree` | 14 | 14 |  | 12 | 16 | 16 | line | 1 | 2.75 | inline | acpmux-header-tool |
| `agent-session/acpmux/header/PullRequestChip.tsx:66` | `git.pullrequest` | 14 | 14 |  | 12 | 16 | 16 | line | 1 | 2.75 | inline | acpmux-header-tool |
| `agent-session/acpmux/header/WorktreePill.tsx:53` | `git.worktree` | 14 | 14 |  | 12 | 16 | 16 | line | 1 | 2.75 | inline | acpmux-header-tool |
| `agent-session/acpmux/newtab/NewTabScreen.tsx:2493` | `rowGlyphName(returnAction)` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/newtab/NewTabWidgets.tsx:288` | `status.attention` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | nt-widget-notice |
| `agent-session/acpmux/offer/OfferOptions.tsx:116` | `defaults?.machine ?` | 12 | 12 |  | 13 | 18 | 18 | line | 3 | 4.5 | inline | acpmux-task-options-body |
| `agent-session/acpmux/question/QuestionCard.tsx:574` | `agent.question` | 16 | 16 |  | 14 | 22.75 | 22.75 | line | 3.38 | 5.38 | inline | acpmux-question-bar |
| `agent-session/acpmux/question/QuestionCard.tsx:841` | `action.edit` | 16 | 16 |  | 14 | 22.75 | 22.75 | line | 3.38 | 5.38 | inline | acpmux-question-row |
| `agent-session/acpmux/question/QuestionCard.tsx:872` | `action.edit` | 16 | 16 |  | 14 | 22.75 | 22.75 | line | 3.38 | 5.38 | inline | acpmux-question-row |
| `agent-session/acpmux/session-info/ChangesSection.tsx:188` | `agent.chat` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | PR owner line, line-height 16 |
| `agent-session/acpmux/started/SessionStatusLine.tsx:41` | `STATUS[status].glyph!` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | acpmux-session-status-line |
| `agent-session/acpmux/subagents/AgentCard.tsx:105` | `agent.session` | 16 | 16 |  | inh. | inh. | - | - | - | - | inline |  |
| `agent-session/acpmux/subagents/AgentsPill.tsx:67` | `agent.session` | 14 | 14 |  | 13 | 18 | 18 | line | 2 | 3.75 | inline | acpmux-agents-pill |
| `agent-session/acpmux/subagents/SubagentDoneLine.tsx:414` | `action.more` | 14 | 14 |  | 11 | 14 | 14 | line | 0 | 1.75 | inline | cv-iconbtn |
| `agent-session/acpmux/subagents/SubagentGroup.tsx:245` | `agent.session` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | cv-subagent-of__pill |
| `agent-session/acpmux/summary/WorkflowCard.tsx:181` | `tunable.sidebar` | 12 | 12 |  | 12 | 18 | 18 | line | 3 | 4.5 | inline | acpmux-workflow-card__focus |
| `agent-session/acpmux/threadMinimap/PreviewCard.tsx:436` | `status.error` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/github/GitHubPage.tsx:843` | `(state && PULL_GLYPHS[state]) \|\|` | 16 | 16 |  | 11 | 14 | 14 | line | -1 | 1 | inline | gh-lines |
| `pages/github/IconPassGallery.tsx:47` | `action.copy` | 16 | 16 |  | 13 | 18 | 18 | line | 1 | 3 | inline | icon-pass |
| `pages/github/IconPassGallery.tsx:53` | `action.pin` | 16 | 16 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/github/IconPassGallery.tsx:66` | `git.pullrequest` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/github/IconPassGallery.tsx:70` | `git.pullrequest.merged` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/tasks/Glyphs.tsx:29` | `STATUS_ICONS[category]` | 12 | 12 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/tasks/TasksPage.tsx:130` | `action.copy` | 12 | 12 |  | 11 | 14 | 14 | line | 1 | 2.5 | inline | tasks-icon-button |
| `pages/tasks/TasksPage.tsx:161` | `action.add` | 14 | 14 |  | inh. | inh. | - | - | - | - | inline |  |
| `pages/tasks/TasksPage.tsx:752` | `(computed)` | 12 | 12 |  | 12 | 16 | 16 | line | 2 | 3.5 | inline | tasks-plan |
| `pages/tasks/TasksPage.tsx:83` | `account` | 14 | 14 |  | 11 | 14 | 14 | line | 0 | 1.75 | inline | tasks-scope-bar |
| `agent-session/acpmux/ChiefDock.tsx:236` | `STATUS_ICONS[cardStatus]` | 20 | 20 | row | 12 | 16 | 21 | box | 0.5 | 1.03 | row | .acpmux-chief-dock-status 21x21 |
| `agent-session/acpmux/icons/CommandGlyph.tsx:34` | `pack ??` | 14 | 16 |  | 13 | 18 | 16 | box | 0 | 2 | row | drawn inside .nt-row-glyph, so CSS sizes it as RowGlyph |
| `agent-session/acpmux/newtab/RowGlyph.tsx:53` | `NAMES[kind]` | 14 | 16 |  | 13 | 18 | 16 | box | 0 | 2 | row | CSS draws the svg at --nt-glyph-ink: the whole 16 box in the composer, 14/16 of an 18 box (15.75) in the popover |
| `agent-session/acpmux/newtab/RowGlyph.tsx:63` | `agent.chat` | 14 | 16 | row | 13 | 18 | 16 | box | 0 | 0.42 | row | as above |
| `agent-session/acpmux/newtab/StageCards.tsx:180` | `agent.chat` | 14 | 14 |  | 13 | 18 | 16 | box | 1 | 2.75 | row | as above |
| `agent-session/acpmux/newtab/StageCards.tsx:57` | `folder` | 14 | 14 |  | 13 | 18 | 16 | box | 1 | 2.75 | row | .nt-stage-icon 16 box; ProjectBadge's FolderMark in the same column is 14 |
| `agent-session/acpmux/newtab/StageCards.tsx:72` | `folder` | 14 | 14 |  | 13 | 18 | 16 | box | 1 | 2.75 | row | as above |
| `agent-session/acpmux/newtab/StageCards.tsx:82` | `folder` | 14 | 14 |  | 13 | 18 | 16 | box | 1 | 2.75 | row | as above |
| `agent-session/acpmux/newtab/StageCards.tsx:98` | `folder` | 14 | 14 |  | 13 | 18 | 16 | box | 1 | 2.75 | row | chooser trigger in the same card |
| `agent-session/acpmux/offer/OfferOptions.tsx:121` | `folder` | 14 | 14 |  | 13 | 18 | 18 | line | 2 | 3.75 | row | unboxed flex item; 16 would push the folder name 2 px |
| `agent-session/acpmux/session-info/ContextSection.tsx:107` | `disclosure.collapsed` | 16 | 16 |  | 12 | 16 | 16 | box | 0 | 2 | row | .acpmux-session-info-row > svg is the 16 icon box |
| `agent-session/acpmux/subagents/BackgroundTaskTail.tsx:63` | `link.external` | 12 | 12 | row | 12 | 16 | 16 | line | 2 | 2.32 | row | acpmux-running-tray__meta |
| `agent-session/acpmux/subagents/BackgroundTaskTail.tsx:69` | `agent.chat` | 12 | 12 | row | 12 | 16 | 16 | line | 2 | 2.32 | row | acpmux-running-tray__meta |
| `agent-session/acpmux/subagents/TrayLineDetail.tsx:51` | `agent.chat` | 12 | 12 | row | 12 | 16 | 16 | line | 2 | 2.32 | row | acpmux-running-tray__meta |
| `agent-session/acpmux/summary/WorkflowSummary.tsx:129` | `agent.session` | 12 | 12 | row | inh. | inh. | - | - | - | - | row |  |
| `agent-session/acpmux/summary/WorkflowSummary.tsx:219` | `agent.session` | 12 | 12 | row | 12 | 16 | 16 | line | 2 | 2.32 | row | acpmux-workflow__agent |
| `browser-chrome/page-info/PageInfoWindowParts.tsx:66` | `icon` | 16 | 16 | row | 13 | 18 | 20 | column | 2 | 2.42 | row | --piw-icon-column 20 in a 28 row |
| `browser-chrome/page-info/SiteDataWindow.tsx:68` | `action.delete` | 14 | 14 | row | inh. | inh. | - | - | - | - | row |  |
| `kit/presets/SessionList.tsx:80` | `session.icon!` | 16 | 16 | row | inh. | inh. | - | - | - | - | row |  |
| `agent-session/acpmux/chips/PullRequestCard.tsx:125` | `issue ? issueGlyph(state) :` | 14 | 14 |  | 13 | 18 | 20 | badge | 3 | 4.75 | badge | 14 glyph in a 20 tinted circle |
| `agent-session/acpmux/composerPlusMenuModel.tsx:16` | `entry.icon` | 18 | 18 |  | 13 | 18 | 18 | line | 0 | 2.25 | composer | composer glyph set, the named 18 exception (grid.md) |
| `agent-session/acpmux/needsYou/NeedsYou.tsx:258` | `inbox.empty` | 20 | 20 |  | 12 | 16 | - | - | - | - | artwork | empty-state mark above the note |
| `pages/tasks/TasksPage.tsx:117` | `task.status.todo` | 28 | 28 |  | 11 | 14 | - | - | - | - | artwork | empty-owner artwork |
