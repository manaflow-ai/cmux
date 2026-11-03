# Design mode in cmux-next

Status: design and first slice, 2026-10-20. Owner: a328 ("Design mode in cmux-next", group cmux-next app).

## The ask

Lawrence, 2026-10-20: "We need to bring over design mode and have it integrate, have a first-class
integration with both the Chief UI as well as the ACP mocks UI. If I make a highlight I need to be
able to see it as a little card in the ACP thing. I come up with several variations of a design to
show me and I will pick it. For the stuff we inject into the page, we can just bring it over from the
original version."

So, in order:

1. Design mode in cmux-next browser panes, with the page side copied from classic.
2. Every highlight (a clicked element or a drawn region) shows as a small card in an agent chat's
   composer, and goes to the agent with the next message.
3. The same cards in the Chief's Home chat.
4. The agent can answer with several design variations; cmux shows them side by side in the right
   column; the user picks one and the pick goes back to the agent.

## What classic has

Classic Design Mode (#8034, #8393, later #18884, #19190) lives in two places:

- `Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Resources/BrowserDesignModeRuntime.js` (2,198
  lines). One IIFE that installs `globalThis.__cmuxDesignMode` in an isolated WebKit content world.
  It draws the hover outline, the selection badges and the annotation stroke in a closed shadow
  root, builds selectors / XPath / a bounded DOM snippet / computed styles / React component names,
  redacts secrets (password fields, token-like attributes), and posts to
  `webkit.messageHandlers.cmuxDesignMode`: `snapshot`, `exit_requested`, `prompt_reset`,
  `interaction_mode_changed`, `annotation_drawing`, `annotation_cancelled`,
  `annotation_capture_requested`. Its API: `enable`, `destroy`, `snapshot`, `clearSelection`,
  `setMode`, `select`, `removeSelection`, `applyStyle`, `applyText`, `revert`, `revertAll`,
  `flashSelection`, `setSelectionHover`, `prepareCapture`, `finishCapture`, annotation capture.
- The app side (`Sources/Panels/BrowserDesignModeController*.swift`, popover, token cells,
  artifact store, screenshot evaluator, prompt formatter): a native popover composer over the
  page that writes screenshots and `context.json` to disk and pastes a prompt into a terminal agent.

cmux-next today only flips `document.designMode` (contenteditable) behind the same action
(`toggleBrowserDesignMode`, Ctrl-Opt-Cmd-E; Ctrl-Opt-Cmd-D until 2026-10-31, now New Column) and toolbar button (`BrowserPageModes.designMode`).

## Decisions

- **Page code: copied as is.** `BrowserDesignModeRuntime.js` is copied byte for byte into
  `CmuxNextBrowser/Resources/`. The only addition is a prelude that cmux-next evaluates before it:
  in Chromium (CEF) the prelude gives the isolated world a `webkit.messageHandlers.cmuxDesignMode`
  whose `postMessage` calls the DevTools binding `cmuxDesignModePost`. In WebKit no prelude is
  needed: the handler is registered in the isolated world. The runtime never runs in the page's
  world, so a page cannot call the handler, read selections or fake one.
- **Lazy, zero idle cost.** Nothing is injected until the user turns design mode on for a tab. A
  new document starts with it off (as today). WebKit registers one message handler per tab
  (no script); CEF adds its binding only when design mode turns on.
- **Native composer popover: not ported.** The agent chat's composer *is* the composer. The classic
  popover, artifact store and terminal paste stay in classic.
- **Cards are composer chips.** A selection becomes a `text` chip (name `Design: <tag> · host`,
  text = page URL, selector(s), XPath, tag, text, DOM snippet, key computed styles, React component
  names) plus an `image` chip with the crop of the element from the tab's own snapshot. The ids are
  stable per selector, so selecting the same element again replaces its chips instead of adding.
  They go with the next message as every chip does (ACP text + image blocks).
- **Which chat gets the card.** The Chief's Home composer when Home shows in the browser's window
  (Home on the left, the page on the right): the card goes in as two files (`<name>.txt`,
  `<name>.png`, `BrowserDesignModeCardFiles`) through Home's own drop intake. Else the agent chat
  tab in the browser's workspace whose pane was focused last (`PaneModel.focusedAt`). With neither,
  the browser shows a notice.
- **Variations: the pick is a highlight.** `scripts/cmux-next/design-variations.py DIR` writes
  `DIR/index.html`, a grid with one tile per variation file, each tagged
  `data-testid="cmux-variation-<n>"`. The agent opens it in the right column; the person turns on
  design mode and clicks a tile; that card's text starts "Picked design variation <n>: <title>". No
  new page-to-app channel and no new action.
- **One path.** The toolbar button, the palette row, the shortcut and the CLI all run the
  `toggleBrowserDesignMode` action; the action runs `BrowserDesignModeController` (app), which owns
  per-tab state. Routing cards goes through one function.

## Data flow

```
page (isolated world)                         app                                   agent chat page
BrowserDesignModeRuntime.js --post-->  BrowserTabIntent.designMode(Data)  -->  BrowserDesignModeController
  (WebKit handler / CEF binding)                                            .receive(tab, data)
                                                                               parse snapshot
                                                                               new selections -> cards
                                                                               crop tab.snapshot()
                                                                               AgentPageEvent "designSelection"
                                                                                       --> pageHost.ts -> bridge.designSelection
                                                                                           -> composer.attach(chip) x2
```

`BrowserDesignModeCards` (CmuxNextBrowser, pure) turns a snapshot plus page URL into cards and
remembers what was sent per tab, so a snapshot that only moved the scroll position sends nothing.

## Slices

1. **Highlight -> card in an ACP chat** (this change). Runtime port, both engines' message path,
   toggle action rewired, cards with crops into the last-focused agent chat of the workspace.
   Failing-first tests: `BrowserDesignModeCardsTests` (Swift, snapshot -> cards, dedupe, redaction
   kept), `design-selection.test.ts` (host event -> chips).
2. **Removal and edits** (landed: `BrowserDesignModeCards.change` gives removed ids and edited cards; Home takes back its draft attachments by hash, the agent chat composer `detach`es; turning design mode off keeps the cards). A selection removed on the page removes its chips (composer handle gets
   `detach(id)`); style/text edits (`css_diff`) ride on the card; Esc in the page leaves design mode
   (`exit_requested`); drawn regions crop the same way.
3. **Home Chief** (first part landed: cards go to the shown Home composer as files). The native Home composer (`HomeAttachmentIntake`) takes the same cards; the
   target becomes "the chat the user last typed in" across Home and agent tabs. Coordinate with
   a290 (Home attachments open in Files) and a285 (non-image files reach agents): both own the
   attachment intake; this work only adds a source.
- Home composer files: one folder per card under `$TMPDIR/cmux-design-mode`, removed once Home copied them into its blob cache (`attachmentsReady`), the rest at quit and at launch.
4. **Design variations** (landed): `design-variations.py DIR --open` writes the gallery and shows it
   right of the Home chat (`cmux browser right navigate`). A pick (`BrowserDesignModeDelivery`) is
   sent to the shown Home chat at once through a304's `home.sendMessage` ("Picked design variation
   <n>: <title>"); other highlights wait in the composer. Still to do: design mode on by itself in
   the gallery. A `design.variations` tool result (or a fenced `cmux-variations` block)
   with N HTML/URL variants opens a gallery in the right column (same placement as a272/a101's
   "open to the right"), each variant live in its own browser tab tile, one Recommended. Picking one
   sends `Picked variation <n>: <title>` (+ its chip) back to the chat that asked. Coordinate with
   a304 (Send Message, which adds the "send to chat" plumbing a pick reuses).
5. **Markdown and viewers.** Highlighting text in the Markdown viewer or other viewers makes the
   same kind of card (owned by the viewer comment work, not this doc).

## Security

The runtime only runs in cmux's isolated world, top frame only (`isMainFrame` in WebKit; the CEF
binding is per isolated context of the main frame). A page cannot post design messages. Card text
is page content and goes into an agent prompt, so it is bounded (runtime caps: 128 KB snapshot,
2.4 KB snippet, 16 KB text) and the card says where it came from (page URL). Password and
token-like values are redacted by the runtime before they leave the page. Nothing is written to disk.

## Tests and proof

- Swift: `BrowserDesignModeCardsTests` in `CmuxNextBrowserTests`, run on the Mac minis
  (`cmux-ci run --class light --script scripts/ci/package-test-lane.sh --arg=suite
  --arg=Packages/macOS/CmuxNext --arg=BrowserDesignModeCardsTests --label suites`).
- Web: `webviews/test/design-selection.test.ts` (`bun test`).
- In app: a tagged nightly with a browser and an agent chat side by side; before/after screenshots.
