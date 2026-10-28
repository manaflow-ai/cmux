window.CHANGELOG = [
 {
  "version": "1.0.0-nightly.3937488754201",
  "date": "2026-10-20",
  "title": "Computer Use, remote tabs and every chat in one place",
  "intro": "Agents can now see and use your apps, browser tabs can run on another machine, and the sidebar lists every coding-agent chat on this Mac.",
  "items": [
   {
    "id": "add-your-harness",
    "category": "new",
    "title": "Add your own coding agent",
    "body": "From the File menu, the command palette or + in the model picker, see the coding agents on this Mac, sign them in or start a chat. Custom harness… walks you through adding your own agent to the model picker.",
    "action": "Try it"
   },
   {
    "id": "agent-browser-computer-use",
    "category": "new",
    "title": "Agents can use the cmux browser and computer use",
    "body": "Agent sessions that cmux starts now get the cmux browser and Computer Use tools, and Claude Code gets matching skills. Computer use still runs only when you ask for it.",
    "action": "",
    "media": true
   },
   {
    "id": "agent-chat-folder",
    "category": "fixed",
    "title": "Agent chats work in workspaces without a folder",
    "body": "A new agent chat in a workspace with no folder now starts in a private folder for that workspace instead of failing. Choose Folder picks another, and cmux asks once before a chat starts in your home folder.",
    "action": "Try it"
   },
   {
    "id": "agent-routes",
    "category": "new",
    "title": "Switch a chat between proxies without a restart",
    "body": "A route says how an agent reaches its model: its own sign-in, an API key, CodeRouter or any compatible endpoint. Move a chat to another route in its composer's Account menu and it keeps its conversation.",
    "action": ""
   },
   {
    "id": "all-chats-on-device",
    "category": "new",
    "title": "Every chat on your Mac, in one place",
    "body": "cmux finds your Claude Code, Codex, OpenCode, Pi, Gemini CLI, Cursor and Amp chats on this Mac and lists them in All chats at the bottom of the sidebar. Open one to resume it in its own harness; nothing leaves the Mac.",
    "action": "Show Agent History"
   },
   {
    "id": "cloud-open-in-browser",
    "category": "new",
    "title": "Open a Cloud machine's localhost in a browser tab",
    "body": "On the Cloud page, Open in browser now opens the machine's local web server in a Chromium tab. The tab reaches that machine's localhost through its proxy and never this Mac's own localhost.",
    "action": ""
   },
   {
    "id": "cloud-workspace-progress",
    "category": "fixed",
    "title": "New Cloud Workspace shows each step until the terminal opens",
    "body": "New Cloud Workspace opens at once and shows each step, from requesting the machine to ready, with the time since you clicked. The terminal opens when the machine is ready, and a failed step shows why with Retry.",
    "action": "Try it"
   },
   {
    "id": "computer-use-helper-start",
    "category": "new",
    "title": "Turn on Computer Use in Settings",
    "body": "Settings > General > Computer Use starts the signed cmux Computer Use helper, so agents can see and use your apps. Off by default; a development build uses the helper of an installed cmux NIGHTLY, and says so when none is installed.",
    "action": ""
   },
   {
    "id": "computer-use-signed-helper",
    "category": "security",
    "title": "Computer Use keeps its permissions",
    "body": "Computer Use now trusts only the signed cmux helper, so a development build can no longer take over its permissions. Setup now says when the helper and cmux versions differ.",
    "action": ""
   },
   {
    "id": "computer-use-upstream-driver",
    "category": "new",
    "title": "Try the new Computer Use driver",
    "body": "Settings > Computer Use Driver has a new Upstream choice: a separate helper built on the Cua Driver, with its own macOS permissions. Only cmux's own agent sessions can reach it, and Legacy stays the default.",
    "action": ""
   },
   {
    "id": "older-cloud-machines",
    "category": "fixed",
    "title": "Older Cloud and SSH machines stay usable",
    "body": "When a Cloud or SSH machine runs an older cmux, actions it does not support show as unavailable instead of failing with an error. A tab dragged to a new column or a new workspace falls back to a move the machine supports.",
    "action": ""
   },
   {
    "id": "remote-browser-tab-local-host",
    "category": "new",
    "title": "Try a remote browser tab on this Mac",
    "body": "Development builds can open a browser tab whose page runs in a separate Chromium process and streams to the tab as video. Run Open Remote Browser Tab (Local Host); the host stops when you close the tab.",
    "action": "Try it"
   },
   {
    "id": "remote-browser-tab-says-why",
    "category": "fixed",
    "title": "A remote browser tab says why it is not connected",
    "body": "In development builds, a remote browser tab that finds no host, or whose host refuses it, shows “Not Connected” and the reason instead of a blank page. It never stores the host's secret.",
    "action": "Try it"
   },
   {
    "id": "remote-session-old-state-fix",
    "category": "fixed",
    "title": "SSH hosts with an older cmux session connect again",
    "body": "SSH hosts that kept a session from an older cmux no longer fail with “table session_journal has no column named actor”. cmux upgrades the saved session in place and keeps its history.",
    "action": ""
   },
   {
    "id": "remote-tab-datalist-popups",
    "category": "improved",
    "title": "Remote browser tabs show suggestions and popups",
    "body": "In development builds, a field in a remote browser tab shows its suggestion list, and a click fills the field. Extension popups show over the page too.",
    "action": "Open Remote Browser Tab"
   },
   {
    "id": "remote-tab-debug-open",
    "category": "new",
    "title": "Open a remote browser tab in development builds",
    "body": "Development builds can run Open Remote Browser Tab to open a tab whose page streams from a local host. Right-click menus, Cmd-click for background tabs and typed addresses work in the remote page.",
    "action": "Open Remote Browser Tab"
   },
   {
    "id": "remote-tab-popups-past-page-edge",
    "category": "fixed",
    "title": "Remote browser tab popups no longer get cut off",
    "body": "In development builds, date pickers, suggestion lists and extension popups in a remote browser tab show in full near the page edge. They never take the keyboard from the page.",
    "action": "Open Remote Browser Tab"
   },
   {
    "id": "ssh-chat-allow",
    "category": "fixed",
    "title": "Allow works for chats on SSH machines",
    "body": "When a chat on an SSH machine asks to run a command, Allow now runs it there instead of doing nothing. If other agents run on that machine, the chat asks first with a Restart button, and they keep working.",
    "action": ""
   },
   {
    "id": "ssh-chat-folder-trust",
    "category": "fixed",
    "title": "Chats on SSH machines ask to trust their folder",
    "body": "A new chat in an SSH workspace now asks whether you trust its folder on that machine, instead of failing with “not a trusted folder”. It also starts in that workspace's folder on the machine.",
    "action": "New Agent Chat"
   },
   {
    "id": "terminal-from-another-machine",
    "category": "new",
    "title": "A terminal from another machine in any pane",
    "body": "A pane can now hold a terminal that runs on another connected machine, next to your local tabs. It keeps its title and last screen across restarts and while that machine is away.",
    "action": "Open Terminal on Machine Here"
   }
  ]
 },
 {
  "version": "1.0.0-nightly.3913596493801",
  "date": "2026-10-18",
  "title": "Updates that tell you what changed",
  "intro": "Every update now shows what it brought, Restart to Update reacts at once, and terminals and agents keep running across the restart.",
  "items": [
   {
    "id": "acp-shutdown-keeps-agents",
    "category": "fixed",
    "title": "Stopping the agent daemon keeps your agents running",
    "body": "`cmux acp daemon shutdown` now stops only the agent daemon, and the next daemon picks your agents back up. Add `--end-agents` to end every agent too.",
    "action": ""
   },
   {
    "id": "attempt-update-shows-result",
    "category": "fixed",
    "title": "Attempt Update shows what it is doing",
    "body": "Attempt Update now shows its progress and result in the sidebar's update card, like Check for Updates. If the check or download fails, the card says why and offers Retry.",
    "action": "Attempt Update"
   },
   {
    "id": "first-launch-straight-to-work",
    "category": "improved",
    "title": "cmux opens straight to work",
    "body": "The first launch skips the setup window and goes straight to a New Tab page. Your first browser tab offers to import bookmarks, history and passwords, and File > Import from Browser works any time.",
    "action": "Import from Browser"
   },
   {
    "id": "history-cookie-backups",
    "category": "new",
    "title": "See and delete the cookie backups agents leave",
    "body": "When an agent clears cookies, cmux keeps an encrypted copy on your Mac so the agent can undo it. Choose Cookie Backups… on the History page to see these copies and delete one or all of them.",
    "action": "Open History"
   },
   {
    "id": "incognito-cookie-undo-memory-only",
    "category": "security",
    "title": "An agent's incognito cookies never reach the disk",
    "body": "When an agent clears cookies in an incognito browser, the copy kept for undo now stays in memory and is never written to disk. The agent can undo while incognito is open; closing it discards the copy.",
    "action": ""
   },
   {
    "id": "managed-update-policy-downloads",
    "category": "improved",
    "title": "Updates your organization requires download by themselves",
    "body": "When your organization requires a minimum cmux version, the update downloads by itself even with automatic downloads off. When it pins the update channel, cmux on another channel stops downloading its own updates.",
    "action": ""
   },
   {
    "id": "onboarding-no-blue-button",
    "category": "improved",
    "title": "Import from Browser buttons in your theme's colors",
    "body": "The Done and Import buttons of the Import from Browser and Computer Use setup windows now use your terminal theme's own colors instead of a blue accent.",
    "action": "Import from Browser"
   },
   {
    "id": "onboarding-wizard-removed",
    "category": "improved",
    "title": "No more setup wizard",
    "body": "The onboarding wizard is gone, with Continue Setup, the welcome checklist and Import and Sync. Import from Browser (File menu, or the card on your first browser tab) and Computer Use setup each open on their own.",
    "action": ""
   },
   {
    "id": "restart-to-update-after-automatic-download",
    "category": "fixed",
    "title": "Restart to Update works after a background download",
    "body": "When cmux had downloaded an update in the background, Restart to Update did nothing. It now installs the update and reopens cmux, or says why it can't.",
    "action": "Check for Updates"
   },
   {
    "id": "restart-to-update-instant",
    "category": "improved",
    "title": "Restart to Update reacts at once",
    "body": "Restart to Update now reacts at once: the button shows Installing and the windows close while cmux finishes the update. Terminals and agents keep running across the restart.",
    "action": "Check for Updates"
   },
   {
    "id": "terminal-env-not-stored",
    "category": "security",
    "title": "Terminal secrets no longer stay on disk",
    "body": "Reopened terminal tabs keep their folder and allowed environment, and cmux no longer keeps environment values such as tokens or passwords in its saved request history.",
    "action": ""
   },
   {
    "id": "update-card-see-all-changes",
    "category": "improved",
    "title": "See every change before you restart",
    "body": "The Update Ready card shows up to three changes and a See all changes button that opens What's New for that update. Its buttons no longer cut off their labels in a narrow sidebar.",
    "action": "Check for Updates"
   },
   {
    "id": "update-install-checks-before-restart",
    "category": "fixed",
    "title": "A failed update tells you why and offers a manual download",
    "body": "Before Restart to Update quits cmux, it checks that cmux can replace itself, the disk has room and the update is still there. If not, cmux keeps running and shows why, with Try Again and Download Manually.",
    "action": "Check for Updates"
   },
   {
    "id": "updated-card-every-update",
    "category": "improved",
    "title": "cmux tells you what changed after every update",
    "body": "After every update, on every channel, the sidebar shows a “cmux Updated!” card once. See What's New opens the notes for exactly the releases the update brought.",
    "action": "See What's New"
   },
   {
    "id": "whats-new-opens-on-home",
    "category": "fixed",
    "title": "What's New opens from the Home page",
    "body": "What's New did nothing while the Home page showed; now it opens in the window. In a workspace it still opens as a tab.",
    "action": "Try it"
   },
   {
    "id": "whats-new-page",
    "category": "new",
    "title": "See what changed after every update",
    "body": "After cmux updates, a What's New item at the top of the sidebar opens a page with the highlights of every version you missed. Turn it off in Settings with Show What's New After Updates.",
    "action": "Open What's New",
    "media": true
   }
  ]
 },
 {
  "version": "1.0.0-nightly.3911762409401",
  "date": "2026-10-17",
  "title": "A calmer browser",
  "intro": "Chromium tabs use Chrome's own error pages, autofill works, and switching tabs no longer reloads the page.",
  "items": [
   {
    "id": "agent-cookie-clear-undo",
    "category": "fixed",
    "title": "An agent's cookie clear in a WebKit tab can be undone",
    "body": "When an agent clears cookies in a WebKit tab, only that tab's site is cleared, not every site in the profile. cmux keeps an encrypted backup on this Mac so the agent can put the cookies back.",
    "action": ""
   },
   {
    "id": "agent-cookies-chromium-tabs",
    "category": "fixed",
    "title": "Agents can read, set and clear cookies in Chromium tabs",
    "body": "Agents can now read, set and clear cookies in Chromium tabs, the same as in WebKit tabs. A clear removes only the tab's site, and the agent can undo it.",
    "action": ""
   },
   {
    "id": "agents-drive-visible-browser-tabs",
    "category": "improved",
    "title": "Agents drive the browser tabs you can see",
    "body": "Agents that use the browser now open and drive real Chromium or WebKit tabs in your window. Background agent tabs take clicks, typing and screenshots without taking your focus, and agents get a clipboard of their own.",
    "action": ""
   },
   {
    "id": "browser-agent-page-read-budget",
    "category": "improved",
    "title": "Agent page reads stay fast on huge or hostile pages",
    "body": "Agent snapshots and page reads no longer stall on huge pages, large tables or giant labels. A read that hits its size or time limit ends with “…” and says where it stopped.",
    "action": ""
   },
   {
    "id": "browser-device-emulation",
    "category": "new",
    "title": "Emulate phones, tablets and foldables in the browser",
    "body": "Choose Emulate Device… in the browser's Tools menu to view a page as a phone, tablet or foldable from Chrome's device list, in either orientation. Agents and scripts use the same list through `cmux browser devices`.",
    "action": "Emulate device"
   },
   {
    "id": "browser-fast-tab-switch-and-snapshots",
    "category": "improved",
    "title": "Faster tab switches and agent snapshots on large pages",
    "body": "Switching between browser tabs in a pane no longer reloads the page, because the tab you leave stays loaded. Agent snapshots of very large pages are about a third faster.",
    "action": "New Browser Tab",
    "media": true
   },
   {
    "id": "browser-forms-never-sent-twice",
    "category": "fixed",
    "title": "A form is never sent twice by surprise",
    "body": "A tab that shows the result of a form, such as a payment, stays loaded when cmux saves memory, so waking it can't send the form again. WebKit tabs ask before Reload, Back or Duplicate Tab resend a form.",
    "action": "New Browser Tab"
   },
   {
    "id": "browser-link-tabs-chrome-order",
    "category": "improved",
    "title": "Link tabs open where Chrome puts them",
    "body": "Tabs you open from a page's links now line up the way Chrome orders them: right of the page, in the order you clicked.",
    "action": ""
   },
   {
    "id": "browser-navigation-after-failed-load",
    "category": "fixed",
    "title": "Agent navigation after a failed load waits for its own page",
    "body": "When an agent opens a page right after one that failed to load, it now waits for the page it asked for. The next script no longer fails with “has no document” on the old error page.",
    "action": ""
   },
   {
    "id": "browser-new-tab-transparent",
    "category": "improved",
    "title": "The browser's New Tab page shows your window background",
    "body": "The New Tab page in Chromium and WebKit tabs is now transparent, so your window's background shows through instead of a solid dark page. Pages without a background of their own stay white, as in Chrome and Safari.",
    "action": "New Browser Tab"
   },
   {
    "id": "browser-open-target",
    "category": "fixed",
    "title": "Browser tabs from the CLI open where you are",
    "body": "`cmux browser open` and `cmux tab create browser` now open a real browser tab in the caller's pane, or in the focused pane of the front window when you run them from an SSH shell. The tab uses your default browser engine and profile.",
    "action": ""
   },
   {
    "id": "browser-page-notices-above-chromium",
    "category": "fixed",
    "title": "Browser notices show over Chromium pages",
    "body": "Notices at the bottom of a browser page, such as “This tab runs on this Mac” in an SSH workspace and the cookie import card, now show above Chromium pages as they do above WebKit pages.",
    "action": "New Chromium Tab"
   },
   {
    "id": "browser-popups-belong-to-their-session",
    "category": "fixed",
    "title": "A popup belongs to the agent session whose page opened it",
    "body": "When several agent sessions share the headless browser, a popup now follows the rules of the session whose page opened it. Another session's address rules can no longer stop it.",
    "action": ""
   },
   {
    "id": "browser-profile-move-tab-in-place",
    "category": "new",
    "title": "Move a tab to another browser profile in place",
    "body": "Move Tab to Browser Profile keeps the tab where it is and reloads the page in the new profile, with that profile's cookies and site data. Agents can create profiles and move tabs too, but can't delete a profile.",
    "action": "Try it"
   },
   {
    "id": "browser-sessions-do-not-stop-each-other",
    "category": "fixed",
    "title": "One agent's browser session no longer stops another's",
    "body": "When several agent sessions share the headless browser, one session's address rules now apply only to the tabs it drives. Pages another session loads no longer fail with ERR_ABORTED.",
    "action": ""
   },
   {
    "id": "browser-sign-in-and-certificate-warning",
    "category": "improved",
    "title": "Sign-in sheet and safer certificate warnings in WebKit tabs",
    "body": "A site that asks for a user name and password shows a sign-in sheet on its tab, with an optional Remember password box. An untrusted certificate shows a full-page warning with Back to Safety as the default.",
    "action": "New WebKit Tab"
   },
   {
    "id": "browser-site-composer-whole-draft",
    "category": "fixed",
    "title": "Agent posts and emails send exactly the approved draft",
    "body": "When an agent posts on X or LinkedIn or sends a Gmail message through cmux, it checks that the composer holds the whole approved draft before sending. On any mismatch nothing is sent, and the error says where they differ.",
    "action": ""
   },
   {
    "id": "browser-site-readback",
    "category": "fixed",
    "title": "Agent emails, invites and doc edits check their target",
    "body": "Before an agent sends a Gmail message, saves a Calendar event or edits a shared Google file, cmux checks the recipients, times, guests or file against what you approved. On any difference nothing changes, and the error names the field.",
    "action": ""
   },
   {
    "id": "browser-tab-in-machine-workspace",
    "category": "fixed",
    "title": "New Browser Tab works in a machine's workspace",
    "body": "In an SSH or Cloud workspace, New Browser Tab (Cmd-Shift-L) opens a tab on this Mac, marked by a “This Mac” chip in the address bar. If the machine can't run the tab yet, the chip's menu says why and offers Retry.",
    "action": "Try it"
   },
   {
    "id": "chromium-autofill-suggestions-click",
    "category": "fixed",
    "title": "Autofill and suggestion lists work in Chromium tabs",
    "body": "A click on a suggestion under a field in a Chromium tab now fills it: saved emails and addresses, a site's own suggestion lists, and passkey choices. Before, the list showed but a click, or Return on a row, did nothing.",
    "action": "New Chromium Tab"
   },
   {
    "id": "chromium-aw-snap-wording",
    "category": "improved",
    "title": "A crashed Chromium page says \"Aw, Snap!\"",
    "body": "When the page in a Chromium tab crashes or is stopped, the tab now uses Chrome's words: \"Aw, Snap!\", \"Something went wrong while displaying this webpage.\", the error code and a Reload button. WebKit tabs keep their own message.",
    "action": "New Chromium Tab"
   },
   {
    "id": "chromium-error-page-new-tab",
    "category": "fixed",
    "title": "Error pages show in a new Chromium tab",
    "body": "When the first address you open in a new Chromium tab fails, the tab now shows Chrome's warning or error page and the address you typed. Before, the page and the address bar stayed blank.",
    "action": "New Chromium Tab"
   },
   {
    "id": "chromium-error-pages-first",
    "category": "fixed",
    "title": "Chromium tabs show Chrome's own error pages at once",
    "body": "A Chromium tab that can't open a page now goes straight to Chrome's own error page, such as “Your connection is not private” or “This site can't be reached”. cmux's own error view no longer flashes first.",
    "action": "New Chromium Tab"
   },
   {
    "id": "import-passwords-from-page",
    "category": "new",
    "title": "Import passwords from the Passwords page",
    "body": "The Passwords page now has Import from Browser and Import CSV buttons and lists the passwords you saved. Import CSV shows the export steps for Safari and Apple Passwords, 1Password and Bitwarden before you pick the file.",
    "action": "Try it"
   },
   {
    "id": "new-tab-chrome-pages",
    "category": "new",
    "title": "Open Chrome pages from the New Tab field and the address bar",
    "body": "Type a `chrome://` or `about:` address in the New Tab field or the address bar to open it in a Chromium tab instead of searching for it. Where cmux has its own page, such as `chrome://history`, that page opens.",
    "action": "Try it"
   }
  ]
 },
 {
  "version": "1.0.0-nightly.3845050428001",
  "date": "2026-10-12",
  "title": "Workspace groups you can see at a glance",
  "intro": "Groups get colored labels, icons and pins, and ⇧⌘N opens a new window.",
  "items": [
   {
    "id": "address-bar-suggestions-and-calculator",
    "category": "new",
    "title": "Smarter address bar with search suggestions",
    "body": "Get search suggestions from Google, DuckDuckGo, Bing, Brave, Kagi or a custom engine, and see quick math answers as you type. Shift-Delete removes a history entry; Ctrl-N and Ctrl-P move through the list.",
    "action": ""
   },
   {
    "id": "app-store-in-your-window",
    "category": "fixed",
    "title": "The App Store always opens in your window",
    "body": "The App Store never opens a window of its own. With every window closed, App Store brings a window back and shows the store there, the same way Settings does.",
    "action": "Open the App Store"
   },
   {
    "id": "claude-through-coderouter",
    "category": "improved",
    "title": "Agents use your own Claude login by default",
    "body": "New Claude chats, the Chief and its memory now use your own Claude login unless you configure a CodeRouter route. A configured route that cannot run shows a clear message in the Chief instead of a sign-in error.",
    "action": ""
   },
   {
    "id": "cmux-open-url-and-stdin",
    "category": "fixed",
    "title": "cmux open opens URLs, also from stdin",
    "body": "`cmux open <url>` opens a browser tab again, in the pane you run it from or the focused pane. `cmux open -` reads URLs from stdin, so a URL that carries a token never shows in the process list.",
    "action": ""
   },
   {
    "id": "daemon-terminals-bundled-cli",
    "category": "fixed",
    "title": "Plain cmux is this app's CLI in every terminal",
    "body": "Terminals that cmux starts for you, such as agent terminals, now run this app's own `cmux` even when your PATH lists an older one first. Commands like `cmux browser open` no longer fail with an unknown-action error.",
    "action": ""
   },
   {
    "id": "failed-machine-stays-in-sidebar",
    "category": "fixed",
    "title": "A machine that cannot connect stays in the sidebar",
    "body": "When Connect to Machine fails, for example because SSH refuses your key, the machine stays in the sidebar with a red status and the reason. Right-click it to reconnect, install cmux there or copy the SSH error.",
    "action": "Try it"
   },
   {
    "id": "icon-picker-emoji-and-symbols-search",
    "category": "improved",
    "title": "A faster emoji and symbol picker",
    "body": "Set Icon now opens one search for emoji and SF Symbols, with large tiles and your frequently used icons first. Use the arrow keys and Return to pick, and Cmd-K for more actions such as copy and Remove Icon.",
    "action": "Try it"
   },
   {
    "id": "icon-picker-sf-symbols",
    "category": "improved",
    "title": "Every SF Symbol in the icon picker",
    "body": "The icon picker's Symbols tab now lists every symbol on your Mac, with a category bar and keyword search, so \"favorite\" finds the star. Show symbols in one color, in shades of your theme color or in their own colors.",
    "action": "Try it"
   },
   {
    "id": "labels-keep-their-text-width",
    "category": "fixed",
    "title": "Pills, banners and panels show their whole text",
    "body": "Small floating views such as the remote desktop toolbar, workspace hover cards and the address bar's machine chip showed only icons. They now keep their text and truncate only when there's no room.",
    "action": ""
   },
   {
    "id": "new-window-shortcut",
    "category": "improved",
    "title": "⇧⌘N opens a new window",
    "body": "⇧⌘N opens a new window, even while a web page has the keyboard, and ⌥⇧⌘N opens a new incognito window. You can change both shortcuts in Settings.",
    "action": "New Window"
   },
   {
    "id": "pinned-tabs-stay-on-close",
    "category": "improved",
    "title": "Pinned tabs survive Cmd-W and pins can be undone",
    "body": "Cmd-W no longer closes a pinned tab; it moves to the next tab. Edit > Undo reverts a pin, and right-click menus now say Pin or Unpin to match the tab.",
    "action": "Try it"
   },
   {
    "id": "save-shortcuts-from-settings",
    "category": "new",
    "title": "Change keyboard shortcuts in Settings",
    "body": "Set, remove or reset a shortcut on the Keyboard Shortcuts page and it saves to cmux.json at once, with a warning when the keys conflict with another action.",
    "action": ""
   },
   {
    "id": "settings-every-window",
    "category": "fixed",
    "title": "Settings opens with your values in every window",
    "body": "Settings opened in a second window or an incognito window showed \"Settings could not be read from cmux\" with default values that could not be changed. Settings now reads and changes your values in every window, the same as in the first one.",
    "action": "Open Settings"
   },
   {
    "id": "sidebar-number-shortcuts",
    "category": "improved",
    "title": "Cmd+1 opens Home, Cmd+2 to 9 follow the sidebar",
    "body": "Number shortcuts now match what you see: Cmd+1 is Home, Cmd+2 to 9 pick workspaces in sidebar order and skip collapsed rows. Cmd-Ctrl-[ and ] step through sidebar items.",
    "action": ""
   },
   {
    "id": "sidebar-profile-menu",
    "category": "improved",
    "title": "One profile menu in the sidebar corner",
    "body": "The bottom-left corner of the sidebar is now one profile button with bookmarks, downloads, history, extensions, developer tools, Settings, a new tab and a new incognito window. Your space dots sit beside it and stay put.",
    "action": "Try it",
    "media": true
   },
   {
    "id": "sidebar-section-collapse-no-capability-errors",
    "category": "fixed",
    "title": "Sidebar sections collapse, and clearer feature errors",
    "body": "Click a sidebar section header to collapse or expand it, and cmux remembers it after a relaunch. Messages about unavailable features now say what to do instead of showing internal names.",
    "action": "Collapse or Expand Section"
   },
   {
    "id": "smart-arrange-new-panes",
    "category": "new",
    "title": "New terminals can split the screen automatically",
    "body": "Set Settings > General > Columns > New Terminals and Browsers to Split Automatically, and each new terminal gets its own pane by splitting the largest one. Docked columns never split.",
    "action": ""
   },
   {
    "id": "ssh-workspace-start-failure",
    "category": "fixed",
    "title": "A terminal that cannot start on an SSH machine says why",
    "body": "When a workspace's first terminal can't start, for example on a slow SSH machine, the workspace shows why and Return tries again. A failed new SSH workspace names the real cause instead of “not connected”.",
    "action": ""
   },
   {
    "id": "undo-closed-tabs-toast",
    "category": "new",
    "title": "Undo a tab close from a toast",
    "body": "Bring back a tab you closed by mistake with one click or Cmd-Z. Closing several tabs at once offers one Undo that reopens them all in their places.",
    "action": ""
   },
   {
    "id": "workspace-group-icon",
    "category": "new",
    "title": "Give a workspace group an icon",
    "body": "Right-click a group header and choose Appearance > Set Icon to give the group an emoji or symbol in its colored label. The group's Color menu moved into the same Appearance menu.",
    "action": "Set Workspace Group Icon…"
   },
   {
    "id": "workspace-group-pin",
    "category": "new",
    "title": "Pin a workspace group to keep it",
    "body": "Right-click a group header and choose Pin Group to keep it. A pinned group stays in the sidebar, empty and collapsed, after you close all its workspaces, even across a restart.",
    "action": "Pin Group"
   },
   {
    "id": "workspace-groups-labels",
    "category": "improved",
    "title": "Workspace groups you can see at a glance",
    "body": "Each workspace group shows its name in a colored label over a band of the same color, and the arrow keys stop on group headers. Ungroup and Delete Group keep every workspace, and Cmd-Z brings the group back.",
    "action": "Group selected"
   }
  ]
 }
];
