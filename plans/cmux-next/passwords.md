# cmux next: password manager (built-in, and extensions as the default)

Proposal, 2026-10-03. Owner: the password manager lead. Request R67 (Lawrence, 2026-10-04): "make sure cmux-next has password manager, and we can support extensions becoming a browser's default password manager". Inputs: browser.md ("Browser import: passwords and security", "Fork API 15"), passkeys.md, browser-host.md (Secure sign-in sheet, sealed tabs), extensions-matrix.md, react-pages.md, settings-react.md, OWNERSHIP-PRINCIPLES.md, decisions UI-STACK, REACT-PAGES, PAGE-SCHEME-CEF, APP-R1, ONE-CATALOG.

Paths: `next:` = `origin/feat-cmux-next`, `fork:` = manaflow-ai/cef `cmux/8037-ext` (API 16, release `cef-154.0.28-cmux.15` pinned), `chromium:` = Chromium 154.0.8037.58 sources.

## 0. Status in one paragraph

cmux next already runs Chromium's own password manager in every CEF tab: Chrome style attaches `ChromePasswordManagerClient`, the store is the cmux profile's `Login Data` encrypted with the "cmux Safe Storage" Keychain key, import writes into it (fork API 15 `cmux_password_import`), and agent-driven tabs turn it off (`cmux_tab_set_password_fill`). What is missing: a save/update prompt that cmux can show (Chromium anchors its bubble to the toolbar that cmux hides, see 1.1), password generation (Chromium offers it only to Google sync users), a way to see, edit, delete or export saved passwords other than Chromium's own `chrome://password-manager` WebUI, and any handling of an extension that takes over. WebKit tabs have no password manager. Nobody has run the save flow in a cmux-next build.

## 1. Built-in password manager

### 1.1 Save and update prompts

Facts (chromium source): `ChromePasswordManagerClient::PromptUserToSaveOrUpdatePassword` hands a `PasswordFormManagerForUI` to `ManagePasswordsUIController`, which shows `PasswordBubbleViewBase` anchored to `ToolbarButtonProvider::GetBubbleAnchor(kActionShowPasswordsBubbleOrPage)` (the omnibox key icon). cmux pages have no Chromium toolbar (`TopContainerView` height 0, browser.md "Chromium top band"), so where that bubble lands is unknown (UNVERIFIED; it may anchor to the page window's corner or not show). It is also Chromium-styled (blue buttons).

Design: fork hook, the same shape as the extension install prompt handler (`cmux_set_install_prompt_handler`).
- `cmux_set_password_prompt_handler(cb, ctx)`: the fork keeps the `PasswordFormManagerForUI` in a registry under a prompt id and calls the embedder with `{prompt_id, browser_id, kind: save|update, origin, username, other_usernames_count}`. Never the password.
- `cmux_password_prompt_answer(prompt_id, action, username_utf8)`: `save`, `update`, `never` (blocklists the site), `dismiss`. A changed username goes through `OnUpdateUsernameFromPrompt`. The password stays inside Chromium from the form to the store.
- A navigation away or tab close drops the registry entry and sends `CMUX_PASSWORD_PROMPT_GONE`.
- Native Swift prompt anchored to a key glyph in the omnibar (CmuxNextBrowser/UI). Prototype variants behind a Debug Settings switch: popover under the omnibar, a bar at the top of the page, a toast in the pane corner. Lawrence picks.
- Agent-driven tabs never prompt (the fill switch already turns saving off). Incognito never prompts (`IsSavingAndFillingEnabled` requires `!IsOffTheRecord()`).

### 1.2 Autofill

CEF (default engine): Chromium's autofill as is. Its dropdown and the manual fallback are Chromium views anchored to the field inside the page child window, so the toolbar gap does not affect them (UNVERIFIED on a build; their colors come from Chromium's color provider, not Ghostty: check for blue). Chromium on macOS can ask for Touch ID before each fill (`IsBiometricAuthenticationBeforeFillingEnabled`, pref `kBiometricAuthenticationBeforeFilling`); cmux exposes it as a setting (default off, as in Chrome).

Incognito: the cmux off-the-record context's parent is CEF's root `Default` profile, whose store is empty, so incognito windows neither save nor fill. Chrome fills incognito tabs from the parent profile; cmux does not (decision P5).

WebKit (secondary engine): WKWebView has no public password manager API and no access to Safari's or iCloud Keychain's AutoFill for arbitrary sites. WebKit tabs therefore get no save prompt and no autofill in v1, and extensions do not run in WebKit tabs. A later option (slice 9, not planned): a user-initiated "Fill saved password" in the WebKit omnibar key menu that reads one password from the Chromium store (fork reveal, needs the CEF runtime loaded) and types it with the bundled fill script in an isolated `WKContentWorld`, plus a submit observer in that world that feeds the native save prompt. Its cost is starting CEF for a WebKit-only user and a second save detector that pages can spoof.

### 1.3 Password generator

Facts: `PasswordFeatureManagerImpl::IsGenerationEnabled` returns false unless Google password sync is active, and cmux has no Google sign-in. Design: a fork switch `cmux_set_password_generation_enabled(1)` that makes generation available without sync (it still needs filling on, so agent-driven tabs and extension-default profiles get none). Chromium's generation popup and its strong-password rules stay. Setting `browser.passwords.generate` (default true).

### 1.4 Passwords page (`cmux-page://cmux.passwords/`)

React page in `webviews/src/pages/passwords/`, hosted by the shared `PageWebView` (react-pages.md H1b, React UIs lead). Features: list grouped by site, search (site and username), sort, edit username, delete (with undo toast), per-site exceptions ("Never saved" list, remove an exception), weak and reused warnings, import (the existing File > Import Passwords from CSV and browser import), export.

Backend: the Mac app, not the daemon (section 2). The page calls `cmux.passwords.*` over the `cmuxPage` WebKit bridge and Swift answers them itself from the fork's store API (fork API 17, slice 3):

| Op | Result | Notes |
| --- | --- | --- |
| `cmux.passwords.list {profile}` | `[{id, site, url, username, created, last_used, times_used, weak, reused, blocked}]` | metadata only |
| `cmux.passwords.remove {profile, ids[], idempotency_key}` | `{removed}` | |
| `cmux.passwords.username.set {profile, id, username, idempotency_key}` | | |
| `cmux.passwords.exception.remove {profile, id}` | | |
| `cmux.passwords.changed` (event) | `{profile, revision}` | from Chromium's `PasswordStoreInterface::Observer`, no polling |
| native UI ops | `passwords.reveal`, `passwords.copy`, `passwords.editPassword`, `passwords.export` | each opens a native sheet; the reply is a status only |

Plaintext rule (stricter than the brief, recommended): page JS never receives a password, also not after device auth. Reveal shows the password inside the native sheet; Copy writes it with `NSPasteboard` (`org.nspasteboard.ConcealedType` and `TransientType`) and clears it after a setting-controlled delay through an injected `Clock`; Edit password is a secure text field in the native sheet. Each needs LocalAuthentication `deviceOwnerAuthentication` in that sheet; one success covers that one row for that one action. The brief allowed releasing one row's plaintext to the page after the sheet; that puts a password into a WKWebView process and its JS heap, and buys nothing the sheet cannot show.

Compromised (leaked) passwords: Chromium's leak check needs a Google account; not available. Weak and reused are local: the fork computes them in-process with Chromium's `BulkWeakCheck` and reuse utilities and returns flags only.

Export: refused by default (`browser.passwords.allowExport = false`, lockable by managed policy). When on: native confirmation that says the file is plain text, LocalAuthentication, `NSSavePanel`, then fork `cmux_password_export(profile_path, path, done)` runs Chromium's `PasswordManagerPorter` (CSV, mode 0600). This is the only place where cmux writes plaintext passwords to disk, at the user's explicit request; browser.md's "cmux never writes a CSV" gets this one exception (decision P3).

Entry points (one action catalog): `passwords.open` (palette "Passwords", menu Browser > Passwords, omnibar key menu "Manage Passwords", Settings row link, typed `cmux://passwords`), `passwords.open {site}` (filtered). User navigation to `chrome://password-manager/*` and `chrome://settings/passwords` in a CEF tab opens the cmux page instead (one implementation, decision P4).

### 1.5 Import

Exists (browser.md). No change, except the page and the Settings row link to it.

## 2. Ownership and threat model

| State | Owner (single writer) | Others |
| --- | --- | --- |
| Saved passwords, exceptions, password metadata | Chromium's password store of the cmux browser profile (`Profile-<uuid>/Login Data`, "cmux Safe Storage" key), written only through Chromium (fork API) in the Mac app process | Passwords page (metadata projection), Settings row |
| Save/autofill/generation preferences | config actor (cmux.json, `browser.passwords.*`) | the Mac app applies them as Chromium user prefs per profile |
| Which manager controls a profile (cmux or an extension) | Chromium's extension-controlled pref layer (`ExtensionPrefValueMap`) in that profile; cmux never stores a copy | the Mac app reads it (host fact), the Settings row shows it |
| Per-tab fill state | the Mac app (`PasswordFillPolicy`, one function of agent mark, manager and settings) | fork switch per WebContents |

Rules:
- The Rust daemon holds no password and no password metadata. The store is in the app process; a daemon copy of sites and usernames would be a second store outside Chromium's encryption, and the daemon has nothing to serve when the app is not running. This deviates from UI-STACK's "Rust backend" default (decision P1): the page's provider is the Mac app (APP-R1 provider channel when the router exists, the `cmuxPage` bridge until then).
- Secret operations (reveal, copy, edit password, export) run only in the Swift app host behind LocalAuthentication in a native sheet; values are `SecretBytes` (browser.md) and the fork zeroes its copies after the callback.
- Agents never see a password. No socket method, CLI verb, MCP tool, host API or catalog op returns one, and none may be added (browser.md rule, unchanged). Metadata ops are served only on the page bridge for `cmux-page://cmux.passwords`, never on the control socket. A future CLI gets `cmux browser passwords status --json` (manager per profile, counts), no sites or usernames. If Lawrence wants agents to see sites and usernames, that needs an explicit `passwords:metadata` scope that MCP and agents do not get by default (decision P2).
- The Passwords page loads only in a page tab, never in an agent-driven or browser tab; browser automation (`browser.*`, browser host CDP) cannot target page tabs.
- Incognito never saves and never fills (1.2).
- Agent-driven tabs: Chromium filling, saving, generation and prompts off (exists), and the new extension block (3.4).

Existing gap found while writing this (fix first, slice 0): an agent can navigate a CEF tab it drives to `chrome://password-manager/passwords` (`AppBrowserPage.navigate` resolves `chrome://` for CEF tabs) and then `evaluate` there. That page's `chrome.passwordsPrivate.requestPlaintextPassword` and `exportPasswords` put a macOS device-auth prompt in front of the user, and if the user approves, the agent's script gets the plaintext or a CSV. The same path reaches `chrome://extensions` and `chrome://settings`. Fix: agent operations refuse `chrome://` and `chrome-extension://` navigations and refuse `evaluate` while the tab's committed URL has one of those schemes; the browser host's raw CDP relay must refuse `Page.navigate` to them too (browser-host lead).

## 3. Extensions as the default password manager

### 3.1 Chrome's model

An extension with the `privacy` permission sets `chrome.privacy.services.passwordSavingEnabled` (pref `credentials_enable_service`), `autofillAddressEnabled` (`autofill.profile_enabled`) and `autofillCreditCardEnabled` (`autofill.credit_card_enabled`) to false (chromium `chrome/browser/extensions/pref_mapping.cc`). Bitwarden's "Make Bitwarden your browser's default password manager" does exactly this after `chrome.permissions.request({permissions: ["privacy"]})`. The extension's value wins over the user's (extension pref store), and Chrome's settings page shows "<Extension> is controlling this setting" with "Turn off", which disables the extension.

Important detail: in Chrome, `credentials_enable_service = false` stops saving only. `ChromePasswordManagerClient::IsFillingEnabled` does not read it, so Chrome keeps filling saved passwords. R67 asks for both off, so cmux turns filling off itself (3.3).

### 3.2 What the CEF fork supports today

- `chrome.privacy` works: the API suite reports `services.get` with `levelOfControl: controllable_by_this_extension` (extensions-matrix.md). `services.set`, the permission request and the resulting extension-controlled state were never checked.
- CEF's standard preference API on a request context reads the effective value (`GetPreference`) and whether the user may change it (`CanSetPreference` = `IsUserModifiable`, false when an extension controls it), and `AddPreferenceObserver` (CEF API 13401) reports changes. cmux has no enterprise policy, so "not user-modifiable" means "controlled by an extension" (or a command-line switch, which cmux does not pass for these prefs). The shim does not bind these calls yet.
- Which extension controls a pref, and releasing it without disabling the extension, need Chromium internals (`ExtensionPrefValueMap::GetExtensionControllingPref`, `PreferenceAPI::RemoveExtensionControlledPref`): fork API 17. Until then cmux can list enabled extensions that hold the `privacy` permission (`cmux_ext_list`) and name the one candidate, and "Turn off" can disable it (`cmux_ext_set_enabled`, Chrome parity).

### 3.3 Design

- Settings > Browser > Passwords, one row per browser profile (one row when there is one profile): "Password manager: cmux" or "Password manager: Bitwarden (set by the extension)". With an extension in control the row shows its icon, "Use cmux instead" (fork API 17: releases the extension's three prefs; the extension stays installed and keeps its own autofill) and "Manage extension". Without an extension, the row shows the `browser.passwords.*` switches.
- While an extension controls `credentials_enable_service` for a profile: cmux's save prompt never shows (Chromium already stops), Chromium filling, generation and the manual fallback are off in every tab of that profile (`PasswordFillPolicy` sets `cmux_tab_set_password_fill(0)` for live tabs and before the first navigation of new ones; a value Chromium filled earlier stays until reload), the omnibar key glyph is hidden, and the Passwords page shows a banner "Bitwarden manages passwords in this profile" with the saved list still available (read and delete only).
- Reversible: "Use cmux instead" or the extension's own toggle (`set({value: true})` or `clear()`) brings cmux back on the next pref change event; `PasswordFillPolicy` turns filling on for new navigations.
- Per profile: extensions install per `Profile-<uuid>`, Chromium keeps controlled prefs per profile, and the policy evaluates per profile.
- Address and card autofill: cmux has no own UI for them; Chromium's built-in address and card autofill follows the two prefs by itself.

### 3.4 Extension password managers in agent-driven tabs (gap, needs a fork export)

Extensions inject content scripts into every tab, including agent-driven ones. An agent's synthesized click on an extension's inline menu, or an extension's "autofill on page load", fills a password that the agent's `evaluate` can read. cmux's fill switch covers only Chromium's own manager. Proposal: fork `cmux_tab_set_extension_access(browser_id, 0)`: no content scripts, no `scripting.executeScript`/`tabs.executeScript`, no `tabs.sendMessage` to that tab's frames, set before the first navigation like the fill switch and inherited by popups. Alternative without a fork change: refuse to mark a tab agent-driven while a password manager extension is enabled in its profile (blunt). Decision P6 (decided 2026-10-04: fork block in cmux.17, interim app rule now; design in 3.4.1).

### 3.4.1 Fork P6 design (cmux.17): `cmux_tab_set_extension_access`

Interim rule shipped in the app (9e4b05fcaf3, fbcb6b2d398, the agent profile): an agent may drive a page only when no enabled extension of the tab's profile can reach it, or the person allowed it per tab, or the tab is in the clean agent profile. P6 replaces the refusal with a block, so agents can use tabs in the person's profiles without extensions reaching them.

Export (fork API 18): `int cmux_tab_set_extension_access(int browser_id, int allowed)`. Per WebContents, kept as WebContents user data like the password fill switch (`kCmuxEmbedderNoExtensionsKey`); set before the first navigation of every agent-driven tab and inherited by popups and adopted tabs (the app already marks those). Returns 1 when the tab exists.

What `allowed = 0` blocks, each with a fork embedder test (an unpacked MV3 test extension with `<all_urls>` host permissions, a content script that writes a marker into `document.title`, a background worker that tries each API):
1. Manifest content scripts and CSS: renderer side. A new `extensions::mojom::LocalFrame::SetExtensionScriptsBlocked(bool)` sent by `ExtensionWebContentsObserver` for every frame of a blocked WebContents in `ReadyToCommitNavigation` (before document start, so the first document is covered) and on `RenderFrameCreated`. `ExtensionFrameHelper` stores it; `ScriptInjectionManager::InjectScripts` drops pending and user-script injections for a blocked frame, and `UserScriptSetManager::GetAllInjections` returns none. Test: the marker never appears in a blocked tab; it appears in a normal tab of the same profile.
2. Programmatic injection: `scripting.executeScript`, `scripting.insertCSS`, `tabs.executeScript`, `tabs.insertCSS`. Browser side in `ScriptExecutor::ExecuteScript` (and the scripting API's target resolution): fail with "Cannot access this tab" for a blocked WebContents. Test: the worker's calls reject.
3. Messaging into the tab: `tabs.sendMessage`, `tabs.connect`. Browser side in `MessageService` when it opens a channel to a tab's frames. Test: the call rejects with "Could not establish connection".
4. Extension frames inside the page (password manager inline menus are `chrome-extension://` iframes): a navigation throttle on the blocked WebContents cancels subframe navigations to `chrome-extension:` (the app's main-frame guard already covers main frames). Test: an `<iframe src="chrome-extension://<id>/x.html">` in a blocked tab never loads.
5. `chrome.debugger.attach` to the tab and `tabs.captureVisibleTab` for it: refused for a blocked WebContents. Test: both reject.
6. Not blocked, by design and stated in the header: `webRequest`/`declarativeNetRequest` see the tab's network requests (a form POST body can carry a typed value; the Secure sign-in sheet's fill goes through such a POST); `tabs.query`/`tabs.get` return the tab's URL and title. The app's agent marking does not change cookies.

Runtime changes: turning the block on applies to documents committed after the call; the app already rebuilds a live page at the agent's first touch (`TabContentCache.rebuildForAgent`), so no extension script from before stays. Turning it off (the person takes the tab back) applies after the next navigation.

When cmux.17 ships: the app calls the switch next to `cmux_tab_set_password_fill` in `markAgentDriven`, `extension_host_access` in the relay becomes false for blocked tabs, the interim refusal and the per-tab override stay as the fallback for forks below API 18, and Settings may offer "Let extensions run in agent tabs" (default off) later.

### 3.5 Check with real extensions (fleet, throwaway signed-out profiles only)

New ext-e2e checks, Bitwarden first, then 1Password, LastPass, Dashlane, Proton Pass, RoboForm, NordPass, Keeper: (1) the extension's "make default" path (Bitwarden: popup banner) shows cmux's permission prompt for `privacy`; (2) after accept, `credentials_enable_service` is extension-controlled false; (3) a synthetic sign-in form on a local test site shows no cmux prompt and no Chromium fill; (4) the Settings row names the extension; (5) "Use cmux instead" restores the cmux prompt. No real account signs in. Which of the others call `chrome.privacy` at all is unknown (record per extension).

### 3.6 macOS system AutoFill

- cmux as a system credential provider (`ASCredentialProviderExtension`, other apps fill from cmux): not worth it now. It needs an app extension, the AutoFill credential provider entitlement on three App IDs, and a store the extension can read outside Chromium's `Login Data`; it serves other apps, not cmux.
- cmux pages filling from the system's provider (Apple Passwords, 1Password app) in CEF: Chromium on macOS has no such integration for passwords (passkeys go through passkeys.md). The cheap route is Apple's "iCloud Passwords" Chrome extension, which talks to a macOS native messaging host; cmux already has `cmux_add_native_messaging_dir`. Add it to the 3.5 checks; if it works, it is "extension as default" for Apple Passwords at no extra cost.

## 4. Slices (failing test first in each; owners)

| # | Slice | Files (owner) | Window | Gate |
| --- | --- | --- | --- | --- |
| 0 | Agents cannot reach Chromium WebUI: refuse `chrome://`/`chrome-extension://` navigate and evaluate on agent paths | `CmuxNextApp/Control/AppBrowserPage.swift`, new `CmuxNextBrowser/Passwords/AgentURLPolicy.swift` (me); browser host CDP relay (browser-host lead, ask) | none | Swift tests on cmux-mini-6: `agentNavigateToPasswordManagerIsRefused`, `agentEvaluateOnWebUIIsRefused` |
| 1 | `PasswordFillPolicy` (pure): agent mark + manager + settings -> fill on/off per tab; replaces the direct switch calls in `CEFTab+PasswordFill.swift` | `CmuxNextBrowser/Passwords/` (me), `CEFTab+PasswordFill.swift` (me, coordinate with Leo's lane) | none | property tests: agent-driven always off; extension-controlled always off; on only when all allow |
| 2 | Shim: request-context pref read, can-set, observer (standard CEF API, no fork) | `CEFShim/` and `cmux_cef_shim.h` (browser-host lead; I send the patch, one ABI batch) | none | shim ABI test; fixture profile with an extension-set pref in a fork embedder test |
| 3 | Fork API 17: prompt handler, store list/remove/update/reveal/exceptions/export, weak+reused flags, generation without sync, controlling extension + release, extension access per tab | manaflow-ai/cef `cmux/8037-ext` (fork owner publishes; I write the commits on a branch), built on a fleet builder | none | `scripts/test-cmux-embedder.sh` red on cmux.15, green on the new release |
| 4 | Native save/update prompt, three variants behind Debug Settings | `CmuxNextBrowser/Passwords/UI/` (me), strings `Passwords.xcstrings` en+ja | none | Swift tests (prompt state machine, gone-on-navigation), tagged fleet build + `debug.window_snapshot` per variant |
| 5 | Passwords page: React page with a mock provider in the dev loop | `webviews/src/pages/passwords/` (me; shared shell from the React UIs lead) | none | bun tests, tsc, bundle `--check` |
| 6 | Swift provider and native sheets (reveal, copy, edit password, delete, export) | `CmuxNextApp/Passwords/` (me); needs `PageWebView` (React UIs lead H1b) | none | Swift tests with a synthetic store (key generated in the test): `pageNeverReceivesPlaintext`, `revealNeedsDeviceAuth`, `exportRefusedByDefault` |
| 7 | Settings rows + extension-controlled state + "Use cmux instead" | settings descriptors (settings lead; daemon-owned keys after settings-react slice a) + app host fact (me) | none for Swift descriptors; a cmux-tui window if the keys must land in `cmux-config` | default-matches-docs test; ext-e2e checks 3.5 on the fleet |
| 8 | Catalog and CLI: `passwords.open`, `cmux browser passwords status`, app-owned op schema fragments | catalog (ONE-CATALOG owners), Rust CLI | cmux-tui window | `check-action-surfaces.sh`, CLI round trip on a tagged build |
| 9 | WebKit manual fill (optional, not planned) | | none | |

Order: 0 and 1 now (no fork, no window); 2 to the browser-host lead; 3 starts in parallel (the fork build is about 3.5 h per arch); 4 to 7 follow 3; 8 waits for a window.

## 5. Decisions for Lawrence

- **P1. Backend.** The Passwords page's provider is the Mac app, not a Rust daemon module (UI-STACK default). Recommended: Mac app; the daemon holds nothing about passwords.
- **P2. Agent metadata.** Agents and MCP see no sites or usernames (recommended), or an opt-in `passwords:metadata` scope.
- **P3. Export.** Off by default with a setting; when on, native confirmation, device auth, Chromium's CSV writer to a path the user picks. Recommended. Alternative: no export at all.
- **P4. `chrome://password-manager`.** Redirect user navigations to the cmux page once the page reaches parity (recommended), or keep Chromium's page reachable for people. Agents never reach it (slice 0, either way).
- **P5. Incognito fill.** No fill and no save (recommended, today's behavior), or fill from the window's source profile like Chrome.
- **P6. Extension managers in agent-driven tabs.** Fork per-tab extension block (recommended), or refuse agent marking while a password manager extension is enabled.
- **P7. Prompt variant.** After dogfood of the three prototypes.

## 6. Not verified / shortcuts

- I ran nothing on a build. Bubble placement without a toolbar (1.1), Chromium autofill dropdown colors, and whether `chrome.permissions.request({permissions: ["privacy"]})` reaches cmux's prompt handler are UNVERIFIED.
- Chrome's behavior facts come from reading chromium sources at 154.0.8037.58, not from runs.
- The extension list in 3.5 beyond Bitwarden is not checked for `chrome.privacy` use.
- File ownership overlaps with Leo's cc-next-browser lane (import and passwords per browser-host.md); slices 1 and 6 touch files that lane wrote.
