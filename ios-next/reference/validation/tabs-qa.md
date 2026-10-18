# Tabs tab: functional QA (independent)

Date: 2026-10-14 to 2026-10-15. This QA run tests functionality only and changes no
code. Safari on iOS 26 is the reference.

## Setup

- **Build.** `feat-cmux-next-ios-app` at `b497df09bc935c5a85d5c3943762acaf50ab588e`
  ("ios-next/validation: round 21, re-audit 2 fixes measured"). The `ios-next` tree was clean.
  - Scheme `Tabs`, Debug, built with `remote-ios.sh build --slot qa`.
  - The build ran on mini-cmux9s, not mini-cmux15. A first build on mini-cmux15 filled its
    disk: 5.1 GiB was free at the start and 0.6 GiB at the failure. I deleted my DerivedData
    straight away. The `.app` was copied to mini-cmux15.
- **Device.** A dedicated iPhone 17 Pro simulator, `nx-ios-qa`, on iOS 26.5 on mini-cmux15.
  - The simulator is headless. It has no Simulator.app and no hardware keyboard window.
  - Software keyboard runs used `CMUX_NEXT_SOFTWARE_KEYBOARD=1` (see the caveat in bug 5).
  - The simulator and the `qa` slot were deleted on both minis afterwards.
- **Hosts.**
  - **Mock:** `CMUX_NEXT_MOCK=1`, with 5 tabs (3 browser and 2 terminal).
  - **Real:** the cmux15 host, signed in with the test login `aziz-verify@test.cmux.dev`.
    - The secret was copied into a mode-600 file on the mini and read only inside the
      remote shell. It never appeared on a command line.
    - The link was Direct (LAN), at 1 to 2 ms.
  - **Shared host.** At least 4 other clients (c1, c7, c8 and c44) were attached throughout,
    and another audit (reaudit3) created and closed tabs during the run.
    - mini-cmux15's load average was 7 to 17.
    - The grid had 13 to 20 tabs, most of them not mine.
- **Input.** All input used AXe. A long-press drag used `axe batch` with a touch down, a
  1.0 s hold and 20 touch moves, because `axe drag --pre-delay` does not hold the touch.
  Host-side state was checked over Chrome CDP on the mini.
- **Artifacts.**
  - Everything is in `~/nxios-ref/tabs-qa/` on Aziz's Mac.
    - `m-*` files come from the mock host and `r-*` files from the real host.
    - `frames/` holds crops and frame strips.
    - `tools/` holds the helper scripts.
  - Every artifact comes from build `b497df09`.
- **Cleanup.** I closed only the tabs and terminals I had created. Before each close, I read
  the card's label in the accessibility tree and its URL with Copy Link.
  - Closed: 5 browser tabs (Wikipedia ×3 and example.org/qa1 ×2) and 1 terminal (exited
    and then swiped closed).
  - CDP confirmed that none of my URLs remained.

## Ranked bug list

| # | Severity | Bug | Steps | Expected (Safari) | Actual | Freq | Artifacts |
|---|---|---|---|---|---|---|---|
| 1 | **Major** (near blocker) | A streamed page is blank, then drawn at about 1/3 scale in the top-left corner and frozen | Real host. (+) › New Tab, then type `en.wikipedia.org/wiki/Terminal_emulator` and Go. Wait 15 s, tap Reload, then scroll | The page renders full width within about 1 s and scrolls | The page was blank for more than 15 s, through Reload. After a touch, the frame filled only about 134 × 300 pt in the top-left, and the rest stayed white. Scrolling did not move it, though CDP showed Chrome at `scrollY` 1815 and `visibilityState: hidden`. Open on Mac made Chrome `visible`, but the frame stayed at 1/3 scale. The "Viewing on another device" pill appeared only on a later visit. "View here" then gave a correct full-size frame. Another agent's Google card in the grid was also at 1/3 scale. Probable cause: another client on the shared host owned the tab. Even so, the phone drew the wrong-sized frame with no displaced notice for more than a minute | 1/1 new tab, and 2 cards | `r-03-wiki.png`, `r-05-reload.png`, `r-06-scroll.png`, `r-08-scroll-fling.mp4`, `frames/r08.png`, `r-11-openonmac.png`, `r-12-grid.png`, `r-13-open-wiki.png`, `r-14-top.png`, `r-15-viewhere.png` |
| 2 | **Major** | Close All Tabs runs with no confirmation and also closes terminals | Mock. In the grid, tap (…) › Close All Tabs | Safari asks "Close All N Tabs?" in a confirmation sheet | All 5 items closed at once, including the 2 terminals: their shell sessions ended with no confirmation and no undo. The grid then showed a single Start Page | 1/1 | `m-31b-more.png`, `m-32-closeall.png`, `m-33.png` |
| 3 | **Major** | The keyboard from Page Menu › Show Keyboard cannot be dismissed, and the user is stuck | Mock. Open a browser tab (Google search result). Tap Page Menu › Show Keyboard. Then try tapping the page, scrolling the page, swiping down from the keyboard top, and Return | The keyboard can be dismissed by tapping off a field or scrolling, or the bar stays reachable | The keyboard stayed up through every attempt, and the toolbar and tab bar stayed hidden behind it. Nothing returned to the grid or another tab; only relaunching the app did | 1/1 (4 dismiss attempts) | `m-28-showkb.png`, `m-29-kb-stuck.png`, `m-30-kb-scroll.png` |
| 4 | **Major** | A terminal created on the phone on the real host is 80×24 at 8 pt and uses about a quarter of the screen | Real host. Grid (+) › New Terminal. Run `stty size` | The terminal fills the view at the app's font size: mock terminals are 50×34 to 50×38 at 13 pt | The AX value read `grid=80x24 font=8.0`, and `stty size` printed `24 80`. The text was tiny and the bottom three quarters of the view stayed empty, with and without the keyboard | 1/1 (stayed so for the whole session) | `r-28-newterm.png`, `r-29-term-typed.png`, `r-32-top.png` |
| 5 | **Major** (caveat) | Focusing a field inside a streamed page does not raise the keyboard | Real host, Wikipedia. Tap the search icon, then tap the search field | The software keyboard rises, as in Safari | The remote caret showed in the focused field, but no keyboard appeared. Typing was possible only after Page Menu › Show Keyboard. **Caveat:** this run's simulator was in hardware-keyboard mode, and later even the address bar did not raise the keyboard (`r-26-addr-kb.png`). But `grep` finds no "editable focused" signal in `CNBrowserUI` or `host/`, so the app has no path that could raise the keyboard on page focus. Retest with a software keyboard | 2/2 (confounded) | `r-22-search.png`, `r-23-tapfield.png`, `r-24-typed.png` |
| 6 | **Major** | Streamed text is blurry with JPEG artefacts, even at rest | Real host, Wikipedia, after "View here". Wait 3 s | Safari draws crisp text at 3x | After 3 s at rest, the text was soft and showed block artefacts at 3x crop. No sharper frame replaced it | 2/2 shots | `r-15-viewhere.png`, `r-16-settled.png`, `frames/r15-16.png` |
| 7 | Minor (visual) | The "Show on Mac" button is almost unreadable in dark mode | Mock, `CMUX_NEXT_MOCK_BROWSER_MAC=on`, dark. Open the GitHub tab | The primary button label is legible | A light grey label sits on a white glass button. The action itself works (bug list pass) | 3/3 opens | `m-43-notshowing.png`, `frames/m43-44.png` |
| 8 | Minor | A terminal card is blank, or shows stale lines, instead of the screen you left | Mock. Open the grid. Then open zsh, run `echo hello-qa`, hide the keyboard and return to the grid | The card shows the terminal's current screen, as a Safari card shows the page you left | On first open, the zsh card was blank apart from a cursor while the terminal had full content. After the visit, the card shows the top of the buffer ("Last login…"), not the `hello-qa` lines or the prompt | 1/1 each | `m-02-grid.png`, `m-03-zsh.png`, `m-09-grid-back.png` |
| 9 | Minor | After hiding the keyboard, a terminal's last rows are hidden behind the toolbar | Mock zsh. Type `echo hello-qa`, then key bar › Hide Keyboard | The prompt and cursor stay visible | The view shows from "Last login". The `hello-qa` output and the prompt line, about 2 rows, sit blank or under the bottom bar | 1/1 | `m-06-kb.png`, `m-08-hidekb.png` |
| 10 | Minor (accessibility) | The Tabs tab ignores Dynamic Type | Simulator content size AX-XXXL, relaunch. Look at the grid and the browser toolbar | Card titles, the tab count and the Start Page scale, as in Safari | Nothing in the grid or toolbar scales, while Settings scales in the same run. `CNBrowserUI` and `CNAppShell` contain no `dynamicTypeSize` or `relativeTo` call | 1/1 | `frames/m35-36.png`, `m-37-settings-xxxl.png` |
| 11 | Minor (mock only) | "Bring tabs forward on Mac automatically" does nothing on the mock host | Mock, Mac browser access on. Settings › Browser › turn on the toggle. Open the GitHub tab, which is hidden on the Mac | The tab is brought forward with no "Not showing on your Mac" card | The card still shows. Cause: the mock `AppPreferences` writes to the `cmux-next-mock` suite (`AppModel.swift:161`), but `TabsModel` reads `UserDefaults.standard` (`TabsModel.swift:136, 319, 550`). Not testable on the real host, which never reported a tab as hidden | 2/2 | `m-47-bringforward.png`, `m-48-bringforward-later.png` |
| 12 | Minor | Tapping (+) opens a menu instead of a new tab | Grid. Tap (+) once | Safari opens a new tab on tap and shows the menu on a long press | A New Tab / New Terminal menu opens. VoiceOver labels this menu button "New Tab" | 2/2 | `m-22-newtab.png` |
| 13 | Minor | A new tab does not focus the address bar | Grid (+) › New Tab | Safari focuses the address field and raises the keyboard | The Start Page shows with the address field unfocused. The placeholder is cut to "Search or ente…" although the pill is wide | 2/2 | `m-23-newtab-page.png` |
| 14 | Minor | The Back history menu lists a raw `about:blank` entry, and its items are not in the accessibility tree | Real host. Open a new tab, go to a page, follow a link, tap Back, then long-press Back | The list shows page titles, with no blank placeholder entry | One row reads "about:blank" (the new tab's initial target). The rows are not in `describe-ui`, while the Forward menu's rows are | 1/1 | `r-19-backmenu.png` |
| 15 | Minor | The attachment menu hides the composer field | Real terminal. Key bar › composer › (+) | The composer stays visible under its menu | The composer bar disappears while the Files/Photos menu is open | 1/1 | `r-44-composer-sent.png`, `r-45-attach-menu.png`, `frames/r44-45.png` |
| 16 | Minor (copy) | The ended-terminal message gives the wrong reason after `exit` | Real terminal. Run `exit` | The copy fits a shell that exited | It reads "This Terminal Ended on the Mac. The Mac no longer has this terminal, for example after its host restarted." | 1/1 | `r-48-ended.png` |
| 17 | Minor (accessibility) | Hidden or covered controls are exposed, and real controls are missing | Inspect `describe-ui` on the grid, in a terminal and in a page | VoiceOver sees exactly what is on screen | (a) A card's close (X) has no element on any grid, mock or real, though `TabOverview.swift:51` sets one. (b) The terminal key bar, composer and Reload stay in the tree while hidden or covered by the keyboard. (c) Back and Page Menu share one frame. (d) The terminal's Copy, Paste and Select All are `GenericElement`, not buttons. (e) Off-screen "Close <terminal>" buttons sit at (372, 0) | every dump | `.ax` dumps in the log; `m-03-zsh.png`, `m-10-longpress.png` |
| 18 | Minor (visual) | Grid cards scroll under the status bar with no edge effect | Scroll the grid | Safari's overview blurs or fades content under the status bar | The clock and status icons sit on top of card text, and the (…) button covers a card title | always | `m-09-grid-back.png`, `r-12-grid.png` |
| 19 | Minor | Start Page favourites repeat one host | Real host Start Page | One favourite per site | "Example" appears 3 times, for example.com, example.net and example.org, which have the same title | 1/1 | `r-01-launch.png` |

Ranking notes:

- **Bug 1** could come from the shared host: several other clients were attached. Two
  defects remain in either case:
  - the phone drew a mis-scaled frozen frame for more than a minute;
  - it did not say the stream was owned elsewhere until a later visit.
- **Bug 5** is likely real but needs a software-keyboard retest.
- **Not reproduced (0/1 retest):** a zsh history line was once recalled during key-bar
  scrolling. A swipe that starts on the Up Arrow key did not fire it again.

## Pass list

| Area | Check | Result | Artifacts |
|---|---|---|---|
| Grid | Open a card (browser and terminal) | PASS | `m-03-zsh.png`, `r-13-open-wiki.png` |
| Grid | Swipe-close (fling of 130 pt in 0.12 s) | PASS: mock 5 → 4, real 13 → 12 | `m-18-swipeclose.mp4` |
| Grid | Long-press menu: Copy Link, Duplicate Tab, Close Tab | PASS. Copy Link put the correct URL on the pasteboard every time (7 uses). Duplicate inserted the copy after the original. Close Other Tabs was not run | `m-10-longpress.png`, `m-11-dup.png`, `m-12-closetab.png` |
| Grid | A terminal card's long-press menu | Close Tab only. No Rename or Copy (not a Safari item) | `m-13-term-menu.png` |
| Grid | Long press, then drag to reorder: leftward ×3 and upward ×1 | PASS: the cards swap and the count stays 5 in all 4 runs. The re-audit 2 blocker (a leftward drop closing the tab) is fixed | `m-16-reorder2.mp4`, `m-17-reorder-left{,-2,-3}.mp4` |
| Grid | New Tab and New Terminal from (+) | PASS (mock and real) | `m-20-newterm.png`, `r-28-newterm.png` |
| Grid | Last tab: close the only Start Page | PASS: a fresh Start Page opens and the count stays 1, never 0 (Safari behaviour) | `m-34-close-last.mp4` |
| Grid | Empty state | PASS: Start Page with "Sites open on your Mac appear here." | `m-32-closeall.png` |
| Grid | Back to the grid keeps the card you left in view | PASS (3/3: mock zsh, real Ghostty after a swipe-up, real ended terminal) | `m-09-grid-back.png`, `r-57-grid-after-swipeup.png`, `r-49-back-to-terms.png` |
| Grid | Swipe up on the address bar opens the grid | PASS | `r-56-swipeup.mp4` |
| Browser | Address bar: URL entry (real) and search terms (mock, shown as the query) | PASS | `r-03-wiki.png`, `frames/m25-26.png` |
| Browser | Tap a link | PASS: "shell" opened Command-line interface (CDP `location.href`) | `r-17-link.png` |
| Browser | Back and Forward buttons, and the Forward history menu | PASS (CDP confirmed each URL). See bug 14 for the Back menu | `r-18-back.png` |
| Browser | Scroll and fling (after View here) | PASS: CDP `scrollY` followed the gestures. Frame quality: bug 6 | `r-14-top.png` |
| Browser | Text input into a page | PASS through Page Menu › Show Keyboard: "xterm" reached the Wikipedia search and suggestions updated. Automatic focus: bug 5 | `r-24-typed.png` |
| Browser | Page menu: Reload, Copy URL, Show Keyboard, Open on Mac | PASS. Copy URL gave the exact search URL, and Open on Mac made the Chrome tab `visible`. Share and Request Desktop Website were not run | `m-27-pagemenu.png`, `r-10-pagemenu.png` |
| Browser | "Not showing on your Mac", then Show on Mac | PASS (mock): the card clears and the live page shows | `frames/m43-44.png` |
| Browser | Displaced stream, then View here | PASS: the pill shows and View here re-attaches at full size | `r-14-top.png`, `r-15-viewhere.png` |
| Terminal | Typing, Return, and 16-colour SGR | PASS: `redgreen` in the right colours, `TERM=xterm-ghostty` | `r-29-term-typed.png` |
| Terminal | Key bar: ctrl+C, arrows, Paste, Hide Keyboard, horizontal scroll | PASS: `^C` interrupted `sleep 30`, and ← inserted mid-line (`aXbc`) | `frames/r30.png`, `frames/r41-42.png` |
| Terminal | Scrollback after `seq 1 300` | PASS | `r-31-scrollback.png` |
| Terminal | `top` runs, drags over it, `q` quits | PASS. The drags did not corrupt the screen | `r-32-top.png`, `r-33-top-drag.mp4`, `r-35-top-quit.png` |
| Terminal | `codex` (v0.162.1) TUI runs, drag over it, ctrl+C ×2 exits | PASS | `frames/r36-37.png` |
| Terminal | Long press: select, Copy, then Paste from the key bar | PASS: the pasteboard held `copyme-qa-123` and Paste inserted it | `frames/r39.png`, `frames/r40.png` |
| Terminal | Composer: text and Send | PASS: `echo from-composer` ran | `r-44-composer-sent.png` |
| Terminal | Composer: photo attachment | PASS: the photo uploaded to `~/.cmux-next-host/uploads/<id>/photo-1.jpeg` (4.1 MB) and its path was inserted | `r-46-photos.png`, `r-47-attached.png` |
| Terminal | Ended state, then Back to Terminals | PASS: goes to the grid with the ended card in view (copy: bug 16) | `r-48-ended.png`, `r-49-back-to-terms.png` |
| Mac side | A tab opened on the Mac (CDP `PUT /json/new`) shows up live | PASS: 12 → 13 within 4 s | `r-51-mac-new.png` |
| Mac side | A tab closed on the Mac (CDP `/json/close`) disappears live | PASS: 13 → 12 within 4 s | ax log |
| Memory | 16 to 20 tabs; 4 new pages loaded, then 6 rounds of scrolling | PASS: RSS 447 MB → 468–485 MB, then flat at 475 MB (no growth across the rounds) | log in this run |
| Appearance | Dark mode: grid, page and terminal | PASS (apart from bug 7) | `frames/m35-36.png`, `frames/r60-61.png` |
| Appearance | Light mode | PASS | `m-02-grid.png`, `r-02-grid.png` |

## Not tested

- **Reconnect after a host restart.** The cmux15 host is shared by other agents' sessions
  (pid 25014), so it was not mine to restart safely.
- **Rotation.** The headless simulator has no rotation control through `simctl` or AXe.
- **The DevTools-off banner** ("Turn on browser access on your Mac") on the real host. The
  host never reported that state, and I did not exercise the mock's `off` copy.
- **Not run:** Close Other Tabs, Share, Request Desktop Website, and the terminal page menu's
  Rename and Larger/Smaller Text.
- **Frame-quality curves while scrolling.** These were not measured. Bug 6 covers quality at
  rest only.
