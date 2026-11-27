// l10n-allow-file: gallery fixtures, not shipped UI.
// Real nightly-next release notes (files-next.cmux.com/nightly-next, published 2026-10-05..13),
// changes capped at 40 per build, dates moved 7 days earlier so the newest build is the gallery
// clock's "Today" (2026-10-06). The newest build carries the highlight files of its whole span and
// the tightened summary, as the fixed pipeline publishes them; the older builds are as published
// (commit subjects only).
import type { ReleaseNotes } from "./types";

export const realNightlies: ReleaseNotes[] = [
  {
    build: "3832783556401",
    shortVersion: "1.0.0-nightly.3832783556401",
    date: "2026-10-06",
    highlights: [
      {
        id: "agent-cookie-clear-undo",
        title: "An agent's cookie clear in a WebKit tab can be undone",
        body: "When an agent cleared cookies in a WebKit tab, cmux deleted the cookies of every site in that browser profile, so you were signed out everywhere. Now a clear removes only the cookies of the tab's own site. cmux first saves the removed cookies in an encrypted backup on this Mac, and the agent gets an id that puts them back. A backup is deleted when it is restored or when every cookie in it has expired.",
        category: "fixed",
      },
      {
        id: "agent-cookies-chromium-tabs",
        title: "Agents can read, set and clear cookies in Chromium tabs",
        body: "An agent that read, set or cleared cookies in a Chromium tab got an error. These calls now work in Chromium tabs the same way they work in WebKit tabs. A clear removes only the tab's site, and cmux keeps a backup so the agent can undo the clear in that same tab.",
        category: "fixed",
      },
      {
        id: "agent-routes",
        title: "Switch a chat between proxies without a restart",
        body: "A route says how an agent reaches its model: its own sign-in, an API key, the local CodeRouter, a subrouter, CLIProxyAPI or any Anthropic- or OpenAI-compatible endpoint. Add one as a file in ~/.config/cmux/routes and move a chat to it in the composer's Account menu. The chat keeps its conversation: the agent restarts on the new route between turns and resumes where it was. Keys stay in the Keychain or the environment; a route file holds only a reference.",
        action: {
          id: "none",
          title: "Try it",
        },
      },
      {
        id: "browser-agent-page-read-budget",
        title: "Agent page reads stay fast on huge or hostile pages",
        body: 'Agent snapshots, locator reads, page.content, page.markdown, searchText, extract, storageState and tabs.content now read within one page budget (250,000 nodes, 2,000,000 characters, 8 seconds). Names that share a huge label, very long link URLs, large tables, generated text and big field values no longer stall a snapshot. A read that stops early ends with "…" and says where it stopped. The viewport snapshot says "at least" when it could not count every element off screen.',
        category: "improved",
      },
      {
        id: "browser-navigation-after-failed-load",
        title: "Agent navigation after a failed load waits for its own page",
        body: "When an agent opened a page that failed to load and then opened another page, the second navigation could finish early on the first page's error page, so the next script read failed with \"has no document\". The agent now waits for the page it asked for, and a script that runs during a page change keeps the new page's context.",
        category: "fixed",
      },
      {
        id: "browser-new-tab-transparent",
        title: "The browser's New Tab page shows your window background",
        body: "A new browser tab no longer shows a solid dark page before you go somewhere. In Chromium and WebKit tabs, the New Tab page is transparent, so the window's background and glass show through. Web pages that do not set a background of their own stay white, as in Chrome and Safari.\n\nWhen you close a tab that is still on the New Tab page, the undo toast now says \"Closed “New Tab”\", not the page's internal address.",
        category: "improved",
      },
      {
        id: "browser-page-notices-above-chromium",
        title: "Browser notices show over Chromium pages",
        body: 'Notices at the bottom of a browser page, such as "This tab runs on this Mac" in an SSH workspace and the cookie import card, now show above Chromium pages as they do above WebKit pages. Before, a Chromium page covered them.',
        category: "fixed",
      },
      {
        id: "browser-popups-belong-to-their-session",
        title: "A popup belongs to the agent session whose page opened it",
        body: "On the shared headless browser, a popup that an agent's page opened was nobody's until the agent first used it. Another session's address rule could then stop it, for example a remote session stopping a local session's popup that loaded through the local session's proxy. A popup now belongs to the sessions that drive its opener before its first request, so only their rules apply to it.",
        category: "fixed",
      },
      {
        id: "browser-sessions-do-not-stop-each-other",
        title: "One agent's browser session no longer stops another session's page",
        body: "When several agent sessions shared the headless browser, one session's address rule could stop a page that another session was loading. For example, a remote session could stop a local session's page that loaded through its own proxy, and the open failed with ERR_ABORTED. Each session's rule now stops only the tabs that session drives. A new tab belongs to the session that opened it before its first request.",
        category: "fixed",
      },
      {
        id: "browser-site-composer-whole-draft",
        title: "Agent posts and emails send exactly the approved draft",
        body: "When an agent posts on X or LinkedIn or sends a Gmail message through cmux's site helpers, cmux now checks that the composer holds the whole approved draft before it presses Post or Send. Before, it checked only the first 40 characters, so a draft whose end was changed could still be sent. On a mismatch nothing is sent, and the error says where the composer and the draft differ.",
        category: "fixed",
      },
      {
        id: "browser-site-readback",
        title: "Agent emails, invitations and document edits check their target first",
        body: "Before an agent sends a Gmail message through cmux's site helpers, cmux checks that the To, Cc and Bcc recipients and the subject are the ones the user approved. For a reply, the recipients are read when the draft is made, so the draft shows who will receive it. Before an agent saves a Google Calendar event or sends its invitations, cmux checks the title, the start and end time and the guests. Before a confirmed edit of a shared Google Doc, Sheet or Slides file, cmux checks that it is the same file with the same title and sharing, that Find and replace holds the drafted text, and that the selected cells are the drafted range. On any difference, nothing is sent, saved or changed, and the error names the field.",
        category: "fixed",
      },
      {
        id: "chromium-autofill-suggestions-click",
        title: "Autofill and suggestion lists work in Chromium tabs",
        body: "A click on a suggestion under a field in a Chromium tab now fills it: saved emails and addresses, a site's own suggestion lists, and passkey choices. Before, the list showed but a click, or Return on a row, did nothing.",
        category: "fixed",
      },
      {
        id: "chromium-aw-snap-wording",
        title: 'A crashed Chromium page says "Aw, Snap!"',
        body: 'When the page in a Chromium tab crashes or is stopped, the tab now uses Chrome\'s words: "Aw, Snap!", "Something went wrong while displaying this webpage.", the error code and a Reload button. WebKit tabs keep their own message.',
        category: "improved",
      },
      {
        id: "chromium-error-page-new-tab",
        title: "Error pages show in a new Chromium tab",
        body: "When the first address you open in a new Chromium tab fails (an untrusted certificate, a name that does not resolve, a refused connection), the tab now shows Chrome's warning or error page and the address you typed. Before, the page area stayed empty and the address bar was blank until a page had loaded in that tab.",
        category: "fixed",
      },
      {
        id: "chromium-error-pages-first",
        title: "Chromium tabs show Chrome's own error pages at once",
        body: 'A Chromium tab that cannot open a page now shows Chrome\'s own page directly: "Your connection is not private" for a certificate problem (with Advanced and Proceed), "This site can\'t be reached" for a name that does not resolve, a refused or reset connection or a timeout, and Chrome\'s pages for too many redirects and blocked sites. Before, cmux\'s "Can\'t open this page" view showed first for a moment.',
        category: "fixed",
      },
      {
        id: "computer-use-upstream-driver",
        title: "Try the new Computer Use driver",
        body: "Settings > Computer Use Driver has a new choice, Upstream. It runs a separate Computer Use helper built on the upstream Cua Driver, and macOS asks for its permissions separately. Only cmux's own agent sessions of your user can reach that helper; other users on the same Mac and other programs are refused. Legacy stays the default.",
        category: "security",
      },
      {
        id: "history-cookie-backups",
        title: "See and delete the cookie backups agents leave",
        body: "When an agent clears cookies in a browser tab, cmux keeps an encrypted copy on your Mac so the agent can undo the clear. Choose Cookie Backups… on the History page to see the sites these copies belong to and when the agent cleared them. You can delete one copy or all of them. After you confirm, an agent can no longer undo those clears.",
        category: "new",
      },
      {
        id: "incognito-cookie-undo-memory-only",
        title: "An agent's incognito cookies never reach the disk",
        body: "When an agent cleared cookies in an incognito browser store, cmux saved the removed cookies in an encrypted backup file on disk, and a backup that held a session cookie stayed there with no end date. Now an incognito store keeps this undo in memory only. The agent can still undo a clear while the store is open. When the store closes, the undo goes with it.",
        category: "security",
      },
      {
        id: "labels-keep-their-text-width",
        title: "Pills, banners and panels show their whole text",
        body: "Some small floating views showed only their icons and buttons because their text was squeezed to nothing: the remote desktop toolbar and banners, the Computer Use helper panel in onboarding, a workspace hover card's details and the machine chip in the address bar. Each one now keeps its text and truncates only when there is no room.",
        category: "fixed",
      },
      {
        id: "managed-update-policy-downloads",
        title: "Updates your organization requires download by themselves",
        body: 'When your organization sets a minimum cmux version, the newer version now downloads and waits as "Update ready" even if you turned automatic downloads off, so a required update never waits for a download. When your organization pins the update channel, a cmux on another channel no longer downloads its own updates.',
        category: "improved",
      },
      {
        id: "remote-tab-popups-past-page-edge",
        title: "Remote browser tab popups are no longer cut off at the page edge",
        body: "In a remote browser tab, a date picker, a suggestion list or an extension popup now shows in its own small window above the page. A popup near the page edge, or in a page shorter than the popup, shows in full. It moves with the window, and it never takes the keyboard from the page.",
        category: "fixed",
      },
      {
        id: "restart-to-update-after-automatic-download",
        title: "Restart to Update works when macOS downloaded the update on its own",
        body: "When cmux had downloaded an update in the background with automatic updates turned on, clicking Restart to Update did nothing. The click now installs that update and reopens cmux. If an update can't start, cmux now says so instead of leaving the button without effect.",
        category: "fixed",
      },
      {
        id: "restart-to-update-instant",
        title: "Restart to Update reacts at once",
        body: "Restart to Update now answers in the next frame: the button shows Installing and the cmux windows leave the screen at once, while cmux finishes the update. The copy of the previous version that cmux keeps for a rollback is now made when the update finishes downloading, not when you click, so the click does no disk work. Terminals and agents keep running across the restart. With unsaved documents, cmux asks about them first, as before.",
        category: "improved",
      },
      {
        id: "terminal-from-another-machine",
        title: "A terminal from another machine in any pane",
        body: "A pane can now hold a terminal that runs on another connected machine, next to your local tabs. The tab keeps its place, title and last screen text after a restart, and it shows the last screen while that machine is away. The terminal keeps running on its machine when no tab shows it.",
        action: {
          id: "remote.openTerminalHere",
          title: "Open Terminal on Machine Here",
        },
      },
      {
        id: "update-install-checks-before-restart",
        title: "A failed update tells you why and offers a manual download",
        body: "Before Restart to Update quits cmux, it now checks that cmux can replace itself in its folder, that the disk has room, and that the downloaded update is still there. If a check fails, cmux keeps running and shows the reason with Try Again and Download Manually, instead of quitting and not coming back.",
        category: "fixed",
      },
      {
        id: "updated-card-every-update",
        title: "cmux tells you what changed after every update",
        body: "After every update, on every channel including Nightly, the sidebar shows a \"cmux Updated!\" card once. See What's New opens the changelog for exactly the releases the update brought; the card's close button hides it for good. Nothing opens a new window or blocks the screen: you land in your workspace as before.",
        category: "improved",
      },
    ],
    changes: [
      "Settings switches for saving, suggesting and exporting passwords (#20058)",
      "Gallery: mark-unread-menu play holds the 33 ms frame budget (cx-ncc.87) (#20059)",
      "fix(nightly-next): publish release notes after an ordinary publication (cx-urd.28) (#20065)",
      "Offer to save typed passwords in the browser tab's prompt bar (#20049)",
      "cmux-next: child process crash e2e and exception reporting under CrashOnExceptions (cx-d0d.2) (#20062)",
      "cx-d0d.73: a browser tab saves its newest history and scroll before it closes (#20048)",
      "cmux-tui: seed a replacement terminal host with OSC 7501 records (cx-6so.36.10) (#20004)",
      "cmux-next: Cmd-N's new row shows at once, with no list slide (cx-evo3q) (#20053)",
      "cmux-tui: guard that every new split shows its first prompt (cx-6so.56) (#20047)",
      "cx-urd.68: a Computer Use helper still in Apple's queue no longer fails the nightly (#20050)",
    ],
    items: [
      {
        author: "Leo",
        pr: 20058,
        title: "Settings switches for saving, suggesting and exporting passwords",
      },
      {
        author: "Leo",
        pr: 20059,
        title: "Gallery: mark-unread-menu play holds the 33 ms frame budget (cx-ncc.87)",
      },
      {
        author: "Leo",
        pr: 20065,
        title: "fix(nightly-next): publish release notes after an ordinary publication (cx-urd.28)",
      },
      {
        author: "Leo",
        pr: 20049,
        title: "Offer to save typed passwords in the browser tab's prompt bar",
      },
      {
        author: "Leo",
        pr: 20062,
        title: "cmux-next: child process crash e2e and exception reporting under CrashOnExceptions (cx-d0d.2)",
      },
      {
        author: "Leo",
        pr: 20048,
        title: "cx-d0d.73: a browser tab saves its newest history and scroll before it closes",
      },
      {
        author: "Leo",
        pr: 20004,
        title: "cmux-tui: seed a replacement terminal host with OSC 7501 records (cx-6so.36.10)",
      },
      {
        author: "Leo",
        pr: 20053,
        title: "cmux-next: Cmd-N's new row shows at once, with no list slide (cx-evo3q)",
      },
      {
        author: "Leo",
        pr: 20047,
        title: "cmux-tui: guard that every new split shows its first prompt (cx-6so.56)",
      },
      {
        author: "Leo",
        pr: 20050,
        title: "cx-urd.68: a Computer Use helper still in Apple's queue no longer fails the nightly",
      },
    ],
    summary: [
      {
        group: "changed",
        title: "Settings switches for saving, suggesting and exporting passwords",
      },
      {
        group: "changed",
        title: "Offer to save typed passwords in the browser tab's prompt bar",
      },
      {
        group: "changed",
        title: "A browser tab saves its newest history and scroll before it closes",
      },
      {
        group: "changed",
        title: "Cmd-N's new row shows at once, with no list slide",
      },
    ],
  },
  {
    build: "3797234815201",
    shortVersion: "1.0.0-nightly.3797234815201",
    date: "2026-10-02",
    highlights: [],
    changes: [],
    items: [],
  },
  {
    build: "3746432045701",
    shortVersion: "1.0.0-nightly.3746432045701",
    date: "2026-09-29",
    highlights: [],
    changes: [
      "cmux-tui-core: move the closed-workspace terminal create out of mux.rs; share the empty-workspace test setup",
      "Server: ServerHeadlessApproval's event stream is bounded (newest 64) instead of unbounded (check-concurrency)",
      "sidebar: a group made without a name gets the localized default name",
      "test(sidebar): an onto-drop group has a name (red)",
      "style(cmux-browser-host): rustfmt the held input release",
      "feat(cmux-browser-host): the shared headless browser releases keys and buttons left pressed when the last session leaves a tab (parity 36)",
      "test(cmux-browser-host): keys and buttons a session left pressed are released when the last session leaves a headless tab (red, parity 36)",
      "cmux-next actions: regenerate action surfaces report and export",
      "cmux-next actions: tests accept the automation-only agent.openSessionWorkspace",
      "sidebar: the onto band is measured at the card's centre over a loose row (centre band)",
      "test(sidebar): a card centred on a loose row groups with it (red)",
      "sidebar: workspace rows draw no default kind icon, only a user's icon",
      "test(sidebar): a default workspace row draws no icon; a custom icon still draws (red)",
      "sidebar: debug.sidebar_rows reports the live drag's drop probe (card edge, hit row, zone fraction, target)",
      "cmux-next: fix forward Home Chief base reds (window record on FrameClient, Home namespace types, acpmux session strings in every language)",
      "optchat-chief: rustfmt the merge resolution",
      "cmux-tui: fix CLI scope audit B findings (help routing, acp/link globals)",
      "cmux-tui: red tests for CLI scope audit B (help routing, acp/link globals, link help)",
      "test(browser-parity): host backends follow the automation lease; goldens 35 and 37 record the lease values as intentional cmux-next differences",
      'docs(cmux-next): automation lease class "routed responses" (tab.handleEvents, dialog.respond, filechooser.respond): no lease, only the routed session answers',
      "feat(cmux-browser-host): unrouted headless events go to the tab opener's policy log and a host log only the person reads (D2 log)",
      "test(cmux-browser-host): unrouted headless events reach the creator's policy log and the person's tab.info, never an app event (red, D2 log)",
      "Settings: restore home.attachments.keepLocation and the Home section in settings-schema.json (schema hash recomputed), the MDM plist and managed-preferences.md, lost in the feat-cmux-next merges; regenerate the Settings page strings and bundle",
      "backend: the per-frame chief check covers every chief token holding mutate-shared, whatever its install_kind (fail closed, review P3)",
      "backend: failing test: a chief token's socket without install_kind skips the per-frame chief check (red, review P3)",
      "optchat-chief README: start from the checkpoint (Testbox and Mac numbers at 10k/100k/1M), writer contention measured (kept one connection), the week-old copy check",
      "optchat: the start reads what the view needs: optchat-core Memory keeps only the frontier above each level's low and the view's sizes (lazy, sizes by key through Store::node_size) and resumes from a Checkpoint (t, low, view) the host saves every 256 messages and at shutdown; a checkpoint more than 4,096 messages behind or one that does not fit folds as before; the migration's copy of the old files is imported again a week later and deleted when counts and hash match; optchat-chief memory check",
      "optchat test: a 1M-message memory opens in under 500 ms and 48 MB (ignored by default); a restart resumes from a saved checkpoint with the same view, a crash after it folds only the tail as a full load would; a lazy memory equals the full one through 1,000 more messages; a checkpoint that does not fit is refused; the old files' copy is checked again and deleted after a week, kept when it does not match; writer contention bench (red)",
      "Server: server.addServer takes code, name and chief arguments and approves without a window (cmux action run), through the same lookup and approve as the sheet",
      "Server: failing tests: server.addServer with a code approves without a window (red)",
      "optchat-chief: offline browse and import report the migration, not nodes waiting for the host's compactor; README: Mac append numbers from the preflight",
      "cmux-tui: the attachment commands dispatch in one line each, so server.rs stays inside its god-file baseline",
      "optchat-chief README: State and storage (owner, file, tables, atomicity, export, backup, migration, resource numbers); memory verbs, backup settings and files",
      "optchat-chief test: a pending turn, its items and the cursor survive a host restart through the memory database",
      "optchat-chief: images survive a mid native turn delivery and a host restart",
      "Home: the attachment fetch cache keeps at most 512 MB; least recently used files go first, never the file a fetch returns (a cache hit counts as a use)",
      "cmux-tui: the local attachment store has a 10 GB total cap; a begin that does not fit evicts the oldest records no message references, then refuses with storage_full",
      'optchat-chief: after each turn\'s commit, the text export is pushed to a private manaflow-ai/chief-memory-<chief id> repository (created with gh on the first push, never forced); gitleaks or a built-in token scan of the added lines holds the push on a hit (backup.json "(backup held: possible secret in message N)", backup_held trace event, backup-allow.txt to release); failed pushes retry with 30 s to 30 min backoff on the persister thread; OPTCHAT_BACKUP_REMOTE / settings.json backup.remote, default on with gh auth except tagged dev homes',
      "optchat-chief test: the memory's text export is pushed to the Chief's backup repository after each turn; a possible secret holds it (status text, backup_held trace event) until allowed; an unreachable remote is retried with doubling backoff; a remote with other history is never forced; backup off and tagged homes push nothing (red)",
      "optchat: the Chief's memory moves to SQLite: one memory.sqlite3 per Chief home (WAL, synchronous=FULL, fullfsync) holds the log, the tree, the host state and FTS5 indexes; logging a turn's messages with the cursor and the pending turn, folding events with their seq, and storing a node are one transaction each; an old JSONL home and host.json are imported once, verified, files kept; the JSONL day files become a deterministic export the git backup commits; `optchat-chief memory export|import|search|stats`",
    ],
    items: [
      {
        title:
          "cmux-tui-core: move the closed-workspace terminal create out of mux.rs; share the empty-workspace test setup",
      },
      {
        title:
          "Server: ServerHeadlessApproval's event stream is bounded (newest 64) instead of unbounded (check-concurrency)",
      },
      {
        title: "sidebar: a group made without a name gets the localized default name",
      },
      {
        title: "test(sidebar): an onto-drop group has a name (red)",
      },
      {
        title: "style(cmux-browser-host): rustfmt the held input release",
      },
      {
        title:
          "feat(cmux-browser-host): the shared headless browser releases keys and buttons left pressed when the last session leaves a tab (parity 36)",
      },
      {
        title:
          "test(cmux-browser-host): keys and buttons a session left pressed are released when the last session leaves a headless tab (red, parity 36)",
      },
      {
        title: "cmux-next actions: regenerate action surfaces report and export",
      },
      {
        title: "cmux-next actions: tests accept the automation-only agent.openSessionWorkspace",
      },
      {
        title: "sidebar: the onto band is measured at the card's centre over a loose row (centre band)",
      },
      {
        title: "test(sidebar): a card centred on a loose row groups with it (red)",
      },
      {
        title: "sidebar: workspace rows draw no default kind icon, only a user's icon",
      },
      {
        title: "test(sidebar): a default workspace row draws no icon; a custom icon still draws (red)",
      },
      {
        title:
          "sidebar: debug.sidebar_rows reports the live drag's drop probe (card edge, hit row, zone fraction, target)",
      },
      {
        title:
          "cmux-next: fix forward Home Chief base reds (window record on FrameClient, Home namespace types, acpmux session strings in every language)",
      },
      {
        title: "optchat-chief: rustfmt the merge resolution",
      },
      {
        title: "cmux-tui: fix CLI scope audit B findings (help routing, acp/link globals)",
      },
      {
        title: "cmux-tui: red tests for CLI scope audit B (help routing, acp/link globals, link help)",
      },
      {
        title:
          "test(browser-parity): host backends follow the automation lease; goldens 35 and 37 record the lease values as intentional cmux-next differences",
      },
      {
        title:
          'docs(cmux-next): automation lease class "routed responses" (tab.handleEvents, dialog.respond, filechooser.respond): no lease, only the routed session answers',
      },
      {
        title:
          "feat(cmux-browser-host): unrouted headless events go to the tab opener's policy log and a host log only the person reads (D2 log)",
      },
      {
        title:
          "test(cmux-browser-host): unrouted headless events reach the creator's policy log and the person's tab.info, never an app event (red, D2 log)",
      },
      {
        title:
          "Settings: restore home.attachments.keepLocation and the Home section in settings-schema.json (schema hash recomputed), the MDM plist and managed-preferences.md, lost in the feat-cmux-next merges; regenerate the Settings page strings and bundle",
      },
      {
        title:
          "backend: the per-frame chief check covers every chief token holding mutate-shared, whatever its install_kind (fail closed, review P3)",
      },
      {
        title:
          "backend: failing test: a chief token's socket without install_kind skips the per-frame chief check (red, review P3)",
      },
      {
        title:
          "optchat-chief README: start from the checkpoint (Testbox and Mac numbers at 10k/100k/1M), writer contention measured (kept one connection), the week-old copy check",
      },
      {
        title:
          "optchat: the start reads what the view needs: optchat-core Memory keeps only the frontier above each level's low and the view's sizes (lazy, sizes by key through Store::node_size) and resumes from a Checkpoint (t, low, view) the host saves every 256 messages and at shutdown; a checkpoint more than 4,096 messages behind or one that does not fit folds as before; the migration's copy of the old files is imported again a week later and deleted when counts and hash match; optchat-chief memory check",
      },
      {
        title:
          "optchat test: a 1M-message memory opens in under 500 ms and 48 MB (ignored by default); a restart resumes from a saved checkpoint with the same view, a crash after it folds only the tail as a full load would; a lazy memory equals the full one through 1,000 more messages; a checkpoint that does not fit is refused; the old files' copy is checked again and deleted after a week, kept when it does not match; writer contention bench (red)",
      },
      {
        title:
          "Server: server.addServer takes code, name and chief arguments and approves without a window (cmux action run), through the same lookup and approve as the sheet",
      },
      {
        title: "Server: failing tests: server.addServer with a code approves without a window (red)",
      },
      {
        title:
          "optchat-chief: offline browse and import report the migration, not nodes waiting for the host's compactor; README: Mac append numbers from the preflight",
      },
      {
        title:
          "cmux-tui: the attachment commands dispatch in one line each, so server.rs stays inside its god-file baseline",
      },
      {
        title:
          "optchat-chief README: State and storage (owner, file, tables, atomicity, export, backup, migration, resource numbers); memory verbs, backup settings and files",
      },
      {
        title:
          "optchat-chief test: a pending turn, its items and the cursor survive a host restart through the memory database",
      },
      {
        title: "optchat-chief: images survive a mid native turn delivery and a host restart",
      },
      {
        title:
          "Home: the attachment fetch cache keeps at most 512 MB; least recently used files go first, never the file a fetch returns (a cache hit counts as a use)",
      },
      {
        title:
          "cmux-tui: the local attachment store has a 10 GB total cap; a begin that does not fit evicts the oldest records no message references, then refuses with storage_full",
      },
      {
        title:
          'optchat-chief: after each turn\'s commit, the text export is pushed to a private manaflow-ai/chief-memory-<chief id> repository (created with gh on the first push, never forced); gitleaks or a built-in token scan of the added lines holds the push on a hit (backup.json "(backup held: possible secret in message N)", backup_held trace event, backup-allow.txt to release); failed pushes retry with 30 s to 30 min backoff on the persister thread; OPTCHAT_BACKUP_REMOTE / settings.json backup.remote, default on with gh auth except tagged dev homes',
      },
      {
        title:
          "optchat-chief test: the memory's text export is pushed to the Chief's backup repository after each turn; a possible secret holds it (status text, backup_held trace event) until allowed; an unreachable remote is retried with doubling backoff; a remote with other history is never forced; backup off and tagged homes push nothing (red)",
      },
      {
        title:
          "optchat: the Chief's memory moves to SQLite: one memory.sqlite3 per Chief home (WAL, synchronous=FULL, fullfsync) holds the log, the tree, the host state and FTS5 indexes; logging a turn's messages with the cursor and the pending turn, folding events with their seq, and storing a node are one transaction each; an old JSONL home and host.json are imported once, verified, files kept; the JSONL day files become a deterministic export the git backup commits; `optchat-chief memory export|import|search|stats`",
      },
    ],
  },
  {
    build: "3745619200201",
    shortVersion: "1.0.0-nightly.3745619200201",
    date: "2026-09-29",
    highlights: [],
    changes: [
      "plans: remote-desktop coordination line for B2",
      "cmux-encode: VideoToolbox encodes captured IOSurfaces with no CPU copy (B2)",
      "cmux-encode: red tests for IOSurface encoding with no CPU copy (B2)",
      "images/cmux-vm: pin cmux-tui and cmux-tui-hook 86e134ee0a4e (artifacts run 37442316116, contains b1cc37e52362)",
      "cmux-next sidebar chrome: the toggle and band borders fade, the account has no rest fill, the corner collapse no longer sticks",
      "cmux-next sidebar chrome: red tests, the toggle and band borders fade, the account has no rest fill, the corner un-sticks",
      "plans: cloud-automation 28, is_person relies on the client-declared kind (cost-only risk; prefer verified origin)",
    ],
    items: [
      {
        title: "plans: remote-desktop coordination line for B2",
      },
      {
        title: "cmux-encode: VideoToolbox encodes captured IOSurfaces with no CPU copy (B2)",
      },
      {
        title: "cmux-encode: red tests for IOSurface encoding with no CPU copy (B2)",
      },
      {
        title:
          "images/cmux-vm: pin cmux-tui and cmux-tui-hook 86e134ee0a4e (artifacts run 37442316116, contains b1cc37e52362)",
      },
      {
        title:
          "cmux-next sidebar chrome: the toggle and band borders fade, the account has no rest fill, the corner collapse no longer sticks",
      },
      {
        title:
          "cmux-next sidebar chrome: red tests, the toggle and band borders fade, the account has no rest fill, the corner un-sticks",
      },
      {
        title:
          "plans: cloud-automation 28, is_person relies on the client-declared kind (cost-only risk; prefer verified origin)",
      },
    ],
  },
  {
    build: "3728109721001",
    shortVersion: "1.0.0-nightly.3728109721001",
    date: "2026-09-28",
    highlights: [],
    changes: [
      "fix(cmux-next): decode the Rust sidebar reply from Data (#17354)",
      "fix(agent pane): use the main sidebar for agent chats (#17348)",
      "fix(cmux-next): split backdrop texture renderer (#17352)",
      "fix(cmux-next): avoid force unwrap in scene listing (#17358)",
      "style(palette): format shared ranker files (#17355)",
      "cmux-next: add deterministic named scene captures (#17344)",
      "fix(cmux-next): clear public inventory boundary false positive (#17350)",
      "fix(cmux-next): split backdrop texture filter type (#17351)",
      "fix(cmux-next): remove obsolete shortcut index writes after hotkey merges (#17353)",
      "plans(cmux-next): pending schema rows for the editor, markdown and files lanes",
      "ci: the FFI release proves the archive links with Apple's toolchain",
      "fix(cmux-next browser): download tokens, temp-file placement, popup match",
      "test(cmux-next browser): download tokens, temp-file placement, popup match (red)",
      "cmux-next: build the layout-reducer FFI as machine code Apple tools can read",
      "ci: check FFI exports per slice with nm -g -U -j, and print what nm saw",
      "notices: Rust target cfg comes from a table generated by rustc --print cfg (1.95.0, Testbox), so gnullvm targets are target_env gnu with target_abi llvm",
      "test(notices): Rust target cfg follows rustc --print cfg (gnullvm is target_env gnu, target_abi llvm) (red)",
      "fix(cmux-next): only a scope row gets the whole-keyword rank",
      "test(cmux-next): only a scope row gets the whole-keyword rank (red)",
      "fix(cmux-browser-host): bound the fetch-cancel records (late engine cancels are swept after 30 s; a timed-out cell is kept only while it has a queued or running fetch)",
      "notices: shipped Rust license texts must satisfy the concluded SPDX expression; add MIT and Apache texts for iroh and iroh-relay, full MIT (Mads Marquart) for objc2, Apache-2.0 for siphasher",
      "test(notices): shipped Rust license texts must satisfy the concluded SPDX expression (red)",
      "test(cmux-browser-host): bounded fetch-cancel records: late engine cancels are swept, timed-out cells are forgotten once their fetches end (red; run registry moved to cdp/fetch_runs.rs)",
      "build: -Demit-themes=false for libghostty-vt and the Ghostty CLI helper",
      "test(notices): no Ghostty build fetches iterm2_themes; fetch lists of libghostty-vt (macOS, Linux) and the CLI helper in the dry run (red)",
      "cmux-next: reserve Cmd-Y for browser history (#17282)",
      "cmux-next: add Ctrl-Cmd pane resize aliases (#17281)",
      "fix(cmux-next): move feed shortcut behind agent chat (#17280)",
      "cmux-next: show shortcut hints on Command or Control hold (#17276)",
      "test(cmux-layout-reducer): the Swift header cases that drag c",
      "ci: the FFI release reads nm once instead of piping it into grep -q",
      "cloud: the fake provider moves to cloud-driver-fake.ts (cloud-driver.ts was over 500 lines)",
      "fix(cmux-layout-reducer): the previous section is the one right above, as in Swift",
      "test(cmux-layout-reducer): a collapsed previous section is not skipped (red)",
      "ci(notices): the libghostty-vt notice check blocks nightly-next and the dry run (green dry run 37268653599)",
      "test(notices): the libghostty-vt notice check blocks nightly-next and the dry run (red)",
      "fix(cmux-next): a palette row whose keyword is the whole query ranks after whole-title matches",
      "test(cmux-next): a palette row whose keyword is the whole query ranks next (red)",
      "cloud: create records the VM's real resources (Freestyle has no size at create); a final resize failure records the VM's real resources; shared default memory constant",
      "test(cmux-next): repair ported sidebar drop fixtures (#17343)",
    ],
    items: [
      {
        title: "fix(cmux-next): decode the Rust sidebar reply from Data",
        pr: 17354,
      },
      {
        title: "fix(agent pane): use the main sidebar for agent chats",
        pr: 17348,
      },
      {
        title: "fix(cmux-next): split backdrop texture renderer",
        pr: 17352,
      },
      {
        title: "fix(cmux-next): avoid force unwrap in scene listing",
        pr: 17358,
      },
      {
        title: "style(palette): format shared ranker files",
        pr: 17355,
      },
      {
        title: "cmux-next: add deterministic named scene captures",
        pr: 17344,
      },
      {
        title: "fix(cmux-next): clear public inventory boundary false positive",
        pr: 17350,
      },
      {
        title: "fix(cmux-next): split backdrop texture filter type",
        pr: 17351,
      },
      {
        title: "fix(cmux-next): remove obsolete shortcut index writes after hotkey merges",
        pr: 17353,
      },
      {
        title: "plans(cmux-next): pending schema rows for the editor, markdown and files lanes",
      },
      {
        title: "ci: the FFI release proves the archive links with Apple's toolchain",
      },
      {
        title: "fix(cmux-next browser): download tokens, temp-file placement, popup match",
      },
      {
        title: "test(cmux-next browser): download tokens, temp-file placement, popup match (red)",
      },
      {
        title: "cmux-next: build the layout-reducer FFI as machine code Apple tools can read",
      },
      {
        title: "ci: check FFI exports per slice with nm -g -U -j, and print what nm saw",
      },
      {
        title:
          "notices: Rust target cfg comes from a table generated by rustc --print cfg (1.95.0, Testbox), so gnullvm targets are target_env gnu with target_abi llvm",
      },
      {
        title:
          "test(notices): Rust target cfg follows rustc --print cfg (gnullvm is target_env gnu, target_abi llvm) (red)",
      },
      {
        title: "fix(cmux-next): only a scope row gets the whole-keyword rank",
      },
      {
        title: "test(cmux-next): only a scope row gets the whole-keyword rank (red)",
      },
      {
        title:
          "fix(cmux-browser-host): bound the fetch-cancel records (late engine cancels are swept after 30 s; a timed-out cell is kept only while it has a queued or running fetch)",
      },
      {
        title:
          "notices: shipped Rust license texts must satisfy the concluded SPDX expression; add MIT and Apache texts for iroh and iroh-relay, full MIT (Mads Marquart) for objc2, Apache-2.0 for siphasher",
      },
      {
        title: "test(notices): shipped Rust license texts must satisfy the concluded SPDX expression (red)",
      },
      {
        title:
          "test(cmux-browser-host): bounded fetch-cancel records: late engine cancels are swept, timed-out cells are forgotten once their fetches end (red; run registry moved to cdp/fetch_runs.rs)",
      },
      {
        title: "build: -Demit-themes=false for libghostty-vt and the Ghostty CLI helper",
      },
      {
        title:
          "test(notices): no Ghostty build fetches iterm2_themes; fetch lists of libghostty-vt (macOS, Linux) and the CLI helper in the dry run (red)",
      },
      {
        title: "cmux-next: reserve Cmd-Y for browser history",
        pr: 17282,
      },
      {
        title: "cmux-next: add Ctrl-Cmd pane resize aliases",
        pr: 17281,
      },
      {
        title: "fix(cmux-next): move feed shortcut behind agent chat",
        pr: 17280,
      },
      {
        title: "cmux-next: show shortcut hints on Command or Control hold",
        pr: 17276,
      },
      {
        title: "test(cmux-layout-reducer): the Swift header cases that drag c",
      },
      {
        title: "ci: the FFI release reads nm once instead of piping it into grep -q",
      },
      {
        title: "cloud: the fake provider moves to cloud-driver-fake.ts (cloud-driver.ts was over 500 lines)",
      },
      {
        title: "fix(cmux-layout-reducer): the previous section is the one right above, as in Swift",
      },
      {
        title: "test(cmux-layout-reducer): a collapsed previous section is not skipped (red)",
      },
      {
        title:
          "ci(notices): the libghostty-vt notice check blocks nightly-next and the dry run (green dry run 37268653599)",
      },
      {
        title: "test(notices): the libghostty-vt notice check blocks nightly-next and the dry run (red)",
      },
      {
        title: "fix(cmux-next): a palette row whose keyword is the whole query ranks after whole-title matches",
      },
      {
        title: "test(cmux-next): a palette row whose keyword is the whole query ranks next (red)",
      },
      {
        title:
          "cloud: create records the VM's real resources (Freestyle has no size at create); a final resize failure records the VM's real resources; shared default memory constant",
      },
      {
        title: "test(cmux-next): repair ported sidebar drop fixtures",
        pr: 17343,
      },
    ],
  },
];
