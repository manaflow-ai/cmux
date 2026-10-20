# Shared projections: views that survive a switch

Status: pattern and first fixes, 2026-10-20. Leo: switching tabs or workspaces made views reload,
re-fetch and replay their entrance animations (New Tab's recent chats, the composer, the agent pane).
Each view should display one shared projection of its data, with no per-instance reload and no
animation unless the data changed.

## 1. What a switch is

Every tab's agent page (New Tab or chat) is its own WKWebView, cached by tab id in
`AgentTabStore.views` (`CmuxNextApp/AgentTabs.swift`). A tab switch hides the view
(`PaneContentView+Parking.swift`); a workspace switch parks the workspace view, hidden, in the
window (`WindowController.parked`, `WindowRootView.show`). Neither reloads or re-handshakes a page.
The page sees only `document.visibilityState` going `hidden`, then `visible`.

A page is rebuilt (load, handshake, acpmux replay, every mount effect) only when:

- hibernation releases a hidden chat page (`AgentPageHibernation`, 60 min default, 10 s floor under
  pressure; New Tab pages are exempt);
- critical memory pressure or a closed or moved workspace tears the pane down;
- Cmd-T, the + button or a new workspace adopts the prewarmed New Tab spare, which remounts the
  screen (`useNewTabAdoption`, `key={newTabGeneration}`).

So "switch away and back" bugs are of two kinds: work a page does on `visibilitychange` or `focus`,
and motion that a hidden page starts or that a catch-up change starts on the first frame back.
Remount bugs are the third kind: component state that starts empty and re-reads.

## 2. Inventory (feat-cmux-next 7a72c460b8f8)

| Where | What happened on a switch or remount | Status |
| --- | --- | --- |
| New Tab chat cards (`newtab/listMotion.ts`) | A change that landed as the page showed again faded and slid cards on the first frame back. Motion started while hidden replayed on show (fixed in #22395 for this list only). | Fixed: entrances go through `entranceAllowed` (this PR). |
| Open Tabs, Recently Closed (`listMotion.ts`) | Same as the cards. | Fixed with the cards (same hook). |
| Agent pane transcript rows (`App.tsx` `enteringRows`, `.acpmux-row--enter`) | A row that streamed in while the tab was hidden got its entrance class; WebKit suspended the CSS animation and played it when the user came back. | Fixed: a row arriving while entrances wait draws in place (`next/shared-projection-transcript`). |
| Streaming reply blocks (`conversation/Markdown.tsx` `.cv-enter`) | Same, for blocks of a reply that streamed while hidden. | Fixed with the rows; the thread glide (`glide`) too. |
| Revealed reply text (`conversation/RevealedMarkdown.tsx`, `.cv-fresh`) | WebKit runs no frames while hidden, so text that streamed while away revealed after the first frame back: its blocks entered and its characters faded in. | Fixed: text received while entrances wait shows at once, with no fade. |
| Code handoff (`conversation/StreamingCode.tsx` `CodeHandoff`) | A fence that closed while hidden cross-faded from plain to highlighted on return. | Fixed: it hands over without the fade. |
| A sent image's thumbnail (`conversation/UserBubble.tsx` `.cv-enter`) | Enters on mount, so a prompt with an image sent from another client while hidden fades in on return. | Follow-up (rare). |
| Every other finite CSS or Web Animation in the page (menus, minimap glide, tree motion, title fades) | Started while hidden, played on return. | Fixed page-wide: `installRevealSettle` finishes finite animations on hide and on show (this PR). |
| All chats list (`newtab/AllChatsList.tsx` `useChatPages`) | List in component state; every mount (spare adoption, workspace reopen) started empty and read its first page again. A switch does not remount it. | Covered by #22115 (`settledCache.ts`, `chatStore.ts`), which removes the mount read. Not duplicated here. |
| New Tab recent chats across pages | Each page listed its own connection's sessions; a hidden window's pages lagged. | Covered by #22115 (one chat store per app run). |
| Composer start-mode chip (`startMode.ts` `watchPage`) | Every return (`visibilitychange` to visible and window `focus`, so twice) asked acpmux again for every pending chat. | Fixed: acpmux watches the settings file and sends `_acpmux/start_mode_changed` (`hub/settings_watch.rs`); `watchPage` is gone. |
| Agent pane `_acpmux/view` (`direct.ts` `showChanged`) | Tells acpmux the chat is shown or hidden, so a turn ending while hidden stays unread. A state write, not a read. | Allowed. |
| Harness health (`App.tsx` `healthStale`) | Re-reads on return only after a Log In ran in a terminal. | Allowed (stale flag). |
| Composer durable draft (`Composer.tsx` `readDurableDraft`) | Read on mount and session change; a switch does not remount the composer. | Remount-only; allowed (a rebuilt page has no other copy). |
| Projects list (`App.tsx` `loadNewTabProjects`) | Read again on each spare adoption. | Remount-only; allowed (the spare's model is not wired before adoption). |

Past attempts: #21620 (closed) reworked `useListMotion` and dropped its motion-off checks; #21621
(closed, replaced by #21960) memoized transcript rows, which is about re-renders per token, not
switches; #21781 and #22052 treated a list swap as a load; #22395 stopped motion on a hidden page,
for the New Tab lists only. Each fixed one view. None handled the catch-up change on the first frame
back, the other views' entrances, or gave a test that every view can use.

## 3. The pattern

1. **One projection per data source, owned above the tab.** A source that more than one page shows
   is owned once, outside any tab: in the host (`ChatsFeed` pushes device chats to every view,
   hidden ones included; `AgentPaneNewTab.warmed`), in acpmux, or in the app run's shared
   `localStorage` (#22115). Inside a page, a view reads a module-level store through
   `useSyncExternalStore`, never component state that starts empty.
2. **Views subscribe and render a snapshot.** A view's first render draws the store's current
   snapshot. Rows are keyed by stable data ids, never by position, mount count or generation.
3. **Remount is cheap and never refetches.** A mount reads the store. It asks its source only when
   the store has nothing yet, or the source pushed a change the store has not taken in
   (`settledCache.ts` `chatsChangedSinceSettled` is the model).
4. **A switch is a reattach, not a change.** No fetch on `visibilitychange` or `focus`. A source
   that cannot announce its changes is the exception, listed below with the fix that removes it.
5. **Animations run on data-change diffs only.** A view decides an entrance from its diff (a row or
   so that arrived; a list that swapped many rows at once is a load) and also asks
   `entranceAllowed()` (`webviews/src/agent-session/shared/pageReveal.ts`): no while hidden, no until
   the first frame after the page shows has passed. The page entry calls `installRevealSettle()`,
   which finishes every finite animation when the page hides and when it shows, so nothing started
   while hidden plays on return. Infinite animations (spinners) keep running. Nothing animates on
   mount.

## 4. Test: switch away and back

`webviews/test/support/pageSwitch.ts`:

```ts
const page = pageSwitch(window);
const load = page.fetch("chats.page", realLoad); // counts each read
// ...render the view with `load`...
const seen = await page.switchAwayAndBack({
  away: () => render(changedWhileHidden),
  back: () => render(catchUpAsItShows),
});
expect(seen).toEqual({ fetches: [], entrances: [] });
```

It hides the page, runs `away`, shows it, runs `back`, lets the first frame back pass, and returns
the fetches and entrances (Web Animations and elements that gained `.cv-enter`,
`.acpmux-row--enter` or `data-kind-switch`) in that window. Each fixed view has a test with it:
`new-tab-switch-back.test.tsx` (chat cards, All chats); `transcript-switch-back.test.tsx` (rows, reply blocks).

## 5. Guard

`scripts/cmux-next/check-switch-fetches.py` reads every agent-page source under
`webviews/src/agent-session/acpmux` (galleries and tests excluded), with comments and strings
masked, and fails on:

- a `visibilitychange` or `pageshow` listener, or a `focus` listener on the window or document,
  whose file and event `ALLOWED_LISTENERS` does not list (an element's own `focus` is not a switch);
- a `useEffect` or `useLayoutEffect` with no dependencies, or only stable read functions
  (`callNative`, `fetchPage`, `load...`, `reload`, `refresh...`), that reads data or is itself a named
  read, unless the line above it carries `// mount-read: <reason>` or `ALLOWED_MOUNT_READS` lists the
  file. An effect that subscribes and reads on each push is the pattern and passes.

Each allowlist entry names its reason or the change that removes it; adding one is a review
question. It runs from `bun run check:switch-fetches` (in `bun run check`), and
`scripts/cmux-next/tests/check-switch-fetches.test.sh` (fixtures, self-test, the tree) runs in the
cmux-next workflow's script tests.

## 6. Exceptions and follow-ups

- **Harness health on every focus** (`harnesses/HarnessesScreen.tsx`): re-reads to catch a Sign In
  run in a terminal; it should re-read only once one ran, as `App.tsx` `healthStale` does.
- **Start mode on return** (`startMode.ts`): fixed. acpmux watches the settings file
  (`hub/settings_watch.rs`) and sends `_acpmux/start_mode_changed` when
  `agents.defaultPermissionMode` changes, so `watchPage` is gone.
- **#22115** carries the cross-page chat store and the All chats remount fix. It should adopt
  `pageSwitch` for its remount test once both land.
- **Hibernated chat pages** rebuild by design (memory). Their wake state is restored from
  `AgentPageHibernation`; a rebuilt transcript is a load (no row entrances), which
  `knownRows` already does.
