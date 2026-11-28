# Browser parity audit

Leo: "we also want to be able to properly motherfucking run in a browser. we already have urls. we already have deeplinks. lets go."

Step 3 of the browser work. Source baseline: `a324f0b733f9d0594a2048a49c5836891c7a29eb`,
2026-11-21. This inventory distinguishes a web renderer from a working browser client.
It changes no shell, authentication, routing, defaults, or native component.

## Evidence rules

**Source** means the named code establishes a seam or limitation, not a live result.
**Browser capture** means a real browser drew the named page; it does not establish that the
page used a real backend. **End to end** requires a user action and readback from the owning
machine, at the exact tested head. **Unverified** is not a pass or a claim of absence.

The diagnostic `webviews/scripts/browser-parity-audit.mjs` enumerates every `pages/*/main.tsx`
and captures Settings, Machines, Files, History and the agent pane in Chromium with no injected
mock, no native bridge and no device credential. It records native bridge presence, page errors,
visible text, screenshots, and the development host's replies to tab/action/native operations.
Some pages choose mocks themselves: their screenshots must retain that qualification.
It is an opt-in diagnostic, with no new gate or workflow. Its successful exit means artifacts
were collected, not that desktop parity passed.

## Surface inventory and gaps

| Surface | Reusable implementation / source evidence | Browser gap and acceptance evidence |
| --- | --- | --- |
| Chat transcript, tools, replies, queue, permissions, attachments, composer, models and session history | `webviews/src/agent-session/acpmux/`; `direct.ts`, `bridgeSocket.ts`, `pageHost.ts` | Same renderer can run in a browser. Prove real list → exact session → prompt → streamed response → stop/queue/permission, uploads and older history. A fixture or harness-injected device hello is not the product flow. |
| New Tab, recent/all chats and search | `acpmux/newtab/`, `chatStore.ts`, `settledCache.ts` | Prove selection, new chat, search, durable draft and cross-client updates against real state. A populated mock list is insufficient. |
| Host/machine discovery and selection | `pages/server-cards`, existing daemon session addresses | Listed sessions may be relay-only; selection must identify whether attach is possible and preserve the chosen host. Prove local and remote ownership, offline and denied states. |
| URLs, deeplinks, browser reload/back/forward | Existing agent addresses and dev-host `sessionMustExist` (`#must`) | Resolve the requested session exactly; missing/denied must never fall back to another chat. Prove cold open, reload, history traversal and reconnect on the real shell. Owned by routing lane. |
| Workspaces, groups, sidebar, splits, tabs, drag/drop, palette and shortcuts | Native desktop chrome; `pages/sidebar-chats` covers only chat rows | Development `tab.open`, `tab.jump`, `action.run` return success with no action; `pane.action` only records an id. A successful reply is not chrome parity. Native surfaces need their agreed host plan; this audit does not port them. |
| Terminal tabs | Existing terminal process stream and browser frontend; RFD's browser renderer plan | Prove input/output, resize, selection/copy/paste, reconnect, scrollback and multiple panes, preserving terminal identity. A chat shell-tool row is not a terminal tab. |
| Browser tabs | Existing remote browser surface and remote desktop protocol | Prove navigation, input, resize, clipboard, downloads, popups, profiles and permission behavior from a browser client. A normal external link opened with `window.open` is not an embedded browser surface. |
| Remote desktop and native application views | Existing remote desktop stack | Browser decoding, input ownership, resize and reconnect need end-to-end evidence. View-only capture is not input parity. |
| Settings and keybindings | `pages/settings`, `pages/keybindings`; `pages/shared/pageClient.ts` | `createPageClient` requires the host reply handler; Settings falls back to `createMockClient` when it is absent. Prove a setting write and readback on the target, including subscription updates; rendering a switch proves neither. |
| Diff, source editor, markdown and files | `pages/diff`, `pages/editor`, `pages/markdown`, `pages/files`; `dev-server/plugins.ts` | Development-only plugins implement local file operations. Production needs authorized host ops/assets, readback after save, readonly refusal, diff navigation and file picker behavior. Dev git reads exclude writes/checkpoints; checkpoint diff is empty. |
| History, bookmarks, browser site data and credentials | `pages/history`, `bookmarks`, `site-settings`, `site-data`, `certificate`, `cookie-import`, `passwords` | Each page needs its real host operations and state subscriptions. Distinguish remote machine data from the browser's own profile; do not import or export credentials for the audit. |
| Cloud machines and progress | `pages/cloud`, `cloud-progress`, `machines`, `server-cards` | Prove existing machine selection and progress against the account. A fixture machine or rendered launch button does not prove provisioning. |
| Apps, artifacts, feed, tasks, stash and integrations | `pages/apps`, `artifacts`, `feed`, `tasks`, `stash`, `github`, `coderouter` | Reuse views, enumerate their page ops, and prove one real read plus each advertised mutation. Native extension placement/host actions need explicit support. |
| Setup, onboarding and mobile pairing | `pages/setup-card`, `onboarding`, `mobile-pairing` | Prove sign-in/device setup and truthful capability states; browser origin is not a desktop install. Auth lane owns credentials and revocation. |
| Activity, usage, releases and diagnostics | `pages/stats`, `task-manager`, `changelog`, `debug-settings`, `glass-parity` | Distinguish real counters and actions from galleries/mocks. Debug and design fixtures are not required user navigation destinations. |
| Home and Chief | `pages/home-channels`, `chief-views`, `chief-usage`, `chief-inspector`; native Home/Chief surfaces | Existing web fragments do not imply a whole Home/Chief port. RFD 0005 explicitly excludes native Home/Chief React ports. Record scope separately; do not silently replace them. |
| Group editor and icon picker | `pages/group-editor`, `icon-picker` | Need production host replies, selection and persistence. A self-contained picker drawing does not prove its caller receives a result. |
| Native integration | `pageHost.ts` and `dev-host/host.ts`: dictation, file dialogs, trust, git writes, notifications and menus | Report supported capabilities truthfully. `native.unsupported` is a limitation to surface, not a generic network error. The dev host's trust echo is not a durable trust mutation. |
| Accessibility, input and layout | Shared DOM pages and desktop layer | Verify keyboard navigation/focus, screen-reader names, text selection, browser shortcut conflicts, zoom and narrow viewport on the actual shell. DOM existence alone is not accessibility proof. |

The diagnostic derives the page-entry list from the tree so additions cannot disappear behind
this grouped inventory. Read the JSON's `pageEntries` at the tested head; there are additional
viewer entrypoints (`diff-page.html`, `editor-page.html`, `markdown-page.html`), the agent pane,
guest pane and preview/gallery tools outside `pages/*/main.tsx`.

## Settled pages and projections

Reuse `plans/cmux-next/shared-projections.md`, `webviews/test/agent-pane-settled-load.test.ts`,
`webviews/test/new-tab-settled-remount.test.tsx` and `webviews/test/support/pageSwitch.ts`.
Desktop hides or parks a page on ordinary switches; it does not load and handshake it again.
The browser shell must establish the same outcome without assuming that native parking exists.

| Transition | Readback required |
| --- | --- |
| Switch away/back, including updates received while hidden | Current rows and reading position remain; unchanged content never re-enters; no redundant fetch on focus/visibility. |
| New tab/spare adoption and remount | First frame uses the retained projection; durable draft, recent chats and selection do not flash empty. |
| Reconnect while streaming and while reading old history | Exact session and cursor remain; queue/events reconcile without duplicate prompt, lost response, or wrong-chat fallback. |
| Cold load and restored long transcript | Record settled time, text/tool row flips, remounts and lost content separately; do not substitute first paint. |
| Sidebar customization/selection rebuild | Incremental updates reach the source as well as the displayed projection; hidden rows return with current content. |
| Cross-client write or revoked device | Real state changes arrive; revoked access stops without borrowing the daemon's identity. Cached content must not be presented as a fresh server result. |

`agent-pane-settled-load.test.ts` supplies a stand-in daemon and renderer regression evidence;
it does not replace the production shell/device journey. The development host retains chat tails
only when a test supplies `cmuxDevHostKept`; this is not durable browser storage by itself.

## Prior art and ownership

- Internal discussion and surface/transport decisions: [RFD 0005](https://github.com/manaflow-ai/cmuxterm-hq/pull/12425).
- [#45112](https://github.com/manaflow-ai/cmux/pull/45112): daemon browser-device enrollment/hello and device-owned hub reads. Observed open at `cc7ae809cceac6323139382d45981e33b2d677dd`; not a browser shell.
- [#45114](https://github.com/manaflow-ai/cmux/pull/45114): real-browser demo harness. Observed open at `429943f3203a9fc29836cb8f28bc4792b24bf1b3`; enrollment/hello are injected by its harness, not initiated by the pane.
- Step 1 owns production serving and pane device handshake; step 2 owns URL/session resolution;
  step 3 owns this inventory and gap publication; step 4 owns recorded production browser journeys.

The meta-problem is conflating web source availability, fixture rendering and real host capability.
The detector is the audit receipt's bridge/error/action evidence plus a real action's owner readback.
Never promote a row to end-to-end solely because a page paints or an action returns `{ok:true}`.

## Run and receipts

Run only on the fleet through `cmux-ci test`, using the webviews dependency/browser setup and
`node webviews/scripts/browser-parity-audit.mjs`. Collect `$FAST_CHECKS_OUT` with `--artifact`.
Record the full head, job/run identity and artifact location below before citing a capture.

Initial publication: source audit complete; fresh browser capture pending. No production browser
parity claim, authenticated machine journey, or settled-page measurement is made by this document.
