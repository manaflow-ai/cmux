# Chrome enterprise policy in the cmux browser

Status: slice 1 on `feat-cmux-next` (2026-10-20).

## Goal

A company that already manages Google Chrome gets the same browser rules in
cmux with no extra setup: the same force-installed extensions (1Password,
Okta, ...), URL blocklist, default search, new tab page, password manager
switch, SSO (Kerberos/Negotiate) allowlists, proxy and certificates. The
admin does nothing new; cmux reads what is already deployed for Chrome.
Settings shows "Managed by your organization" on each row a policy sets, as
Chrome does on chrome://settings.

## Where policies come from

| Source | How cmux reads it |
| --- | --- |
| MDM profile for Chrome (`/Library/Managed Preferences/com.google.Chrome.plist`, device or `/<user>/`) | CFPreferences on `com.google.Chrome`: forced values are mandatory, others recommended (exactly Chrome's `PolicyLoaderMac`). |
| `defaults write com.google.Chrome ...` (no profile) | Same read; such values are not forced, so they are recommended only, as in Chrome. |
| Chrome Enterprise Core (cloud) policy | Chromium reads it natively when started with `--enable-chrome-browser-cloud-management` and an enrollment token in the same domain (CEF documents `chrome_policy_id` as also covering it). Not turned on in slice 1: it enrolls cmux as a browser in the company's Google Admin console, which the company must agree to. See "Later". |
| cmux's browser domain `com.manaflow.cmux.browser` | The same Chrome policy names, for a company that manages cmux apart from Chrome. Its values win over Chrome's, key by key. A forced `HonorChromePolicy` = false makes cmux ignore `com.google.Chrome` (Swift layer and Chromium). |
| cmux's own domain `com.manaflow.cmux` (docs/mdm/managed-preferences.md) | Unchanged. A cmux setting forced there wins over any Chrome policy that maps to it. |

Precedence for a cmux setting, highest first: `com.manaflow.cmux` forced,
browser domain mandatory, Chrome mandatory, team enforced, the user's
cmux.json, `com.manaflow.cmux` recommended, browser/Chrome recommended, team
default, product default. (The Chrome layers enter
`EffectiveSettings.merge` as part of the MDM layer, so they sit where MDM
values sit.)

## Two enforcement paths

1. **Native (Chromium tabs).** cmux's Chromium runs Chrome runtime style,
   so it has Chrome's whole policy stack. `CefSettings.chrome_policy_id` =
   `com.google.Chrome` (shim `cmux_shim_set_chrome_policy_id`, set before
   `CefInitialize`) makes Chromium load and enforce every Chrome policy it
   implements, with Chrome's own semantics, chrome://policy page and
   "Managed by your organization" chrome. This is what gives
   ExtensionInstallForcelist, proxy, certificates and SSO for free.
2. **Mapped (cmux UI and WebKit tabs).** cmux reads a short list of
   policies itself (`ChromePolicyDocument.mappedKeys`) and maps them onto
   cmux settings or enforces them in Swift, so cmux's own UI (omnibar,
   new tab page, Settings) and WebKit tabs agree with Chromium.

Code: `CmuxNextSettings/Managed/Chrome/` (readers, mapping,
`ChromePolicyManagedPreferenceReader`), `CmuxNextBrowser/Core/BrowserURLFilter*.swift`
(Chrome's URL filter format), `CmuxNextBrowser/WebKit/WebKitEngine+URLFilter.swift`,
`CmuxNextApp/BrowserManagedPolicyPreference.swift`.

## Matrix

"Native" = Chromium enforces it in Chromium tabs through `chrome_policy_id`
(verified only by building against the CEF 154 headers so far; see Open).
"Mapped" = cmux maps or enforces it itself.

| Chrome policy | Chromium tabs | WebKit tabs / cmux UI | Slice |
| --- | --- | --- | --- |
| ExtensionInstallForcelist | Native: installs from the update URL, cannot be removed | Mapped to policy key `ExtensionInstallForcelist` (status report). WebKit has no Chrome extensions. | 1 |
| ExtensionSettings, ExtensionInstallBlocklist/Allowlist, ExtensionInstallSources | Native | n/a | 1 (native only) |
| URLBlocklist, URLAllowlist | Native | Mapped: `BrowserURLFilter` blocks main and sub frames in WebKit, page "Your organization blocked this page." | 1 |
| DefaultSearchProviderEnabled/SearchURL/SuggestURL/Name | Native (search engine locked) | Mapped: `browser.searchEngine` = custom, `browser.customSearchEngine.search/suggest`; omnibar uses it, row locked | 1 |
| NewTabPageLocation | Native | Mapped: `browser.newTabPage` (http/https only) | 1 |
| PasswordManagerEnabled | Native | Mapped: `browser.passwords.offerToSave` and `.generate` | 1 |
| HomepageLocation, HomepageIsNewTabPage, ShowHomeButton | Native (cmux shows no Home button) | Unsupported: cmux has no home page concept | — |
| RestoreOnStartup, RestoreOnStartupURLs | Native for Chromium's own startup, which cmux does not use | Unsupported: cmux restores its own workspaces | later |
| AuthServerAllowlist, AuthNegotiateDelegateAllowlist (Kerberos/SPNEGO SSO) | Native | WebKit uses the system's Kerberos tickets already (macOS SSO extension); no allowlist | 1 (native) |
| ProxyMode, ProxyServer, ProxyPacUrl, ProxyBypassList | Native, except where cmux sets its own per-context proxy (remote localhost, `cmux_shim_set_context_proxy`): there cmux's proxy wins for that profile | WebKit follows the system proxy | 1 (native) |
| AutoSelectCertificateForUrls (client certificates) | Native | Unsupported in WebKit (system keychain prompt) | later |
| Certificates (CACertificates, root store) | Chromium on macOS trusts the system keychain, which MDM configures | Same (system keychain) | n/a |
| IntranetRedirectBehavior | Native | Unsupported; cmux's omnibar does its own single-word host check | later |
| go/ links (`go/foo` with no setup) | Works when DNS search domains resolve `go` (corporate network) and the omnibar treats `go/x` as a URL | Same omnibar | separate task |
| DeveloperToolsAvailability, IncognitoModeAvailability, DownloadRestrictions, SafeBrowsing* | Native for Chromium's own UI; cmux's own DevTools/incognito entrypoints do not read them yet | Unsupported | later |
| BrowserSignin, SyncDisabled, CloudPrint*, Chrome-OS-only policies | Native/irrelevant (cmux has no Google sign-in or sync) | n/a | — |

## Settings: "Managed by your organization"

A mapped policy becomes a forced (or recommended) key of the MDM layer, so
the existing machinery applies with no new UI: `managedKeys` marks the row,
the Settings window shows "Managed by your organization" and the lock,
agents and the person cannot change it (`managedKey(forPath:)`), and a value
in cmux.json that the policy overrides gets a `managedOverride` diagnostic.
The managed status file (`managed-status.json`) lists the applied keys and
the policy keys `URLBlocklist`, `URLAllowlist`, `ExtensionInstallForcelist`.
Chromium tabs also show Chrome's own managed UI (chrome://policy,
"Managed by your organization" in its menus) natively.

## Choices made (defaults; change if wanted)

- **Honor Chrome's domain by default.** Zero setup is the point. An org
  that wants cmux unmanaged by its Chrome profile sets `HonorChromePolicy`
  = false in `com.manaflow.cmux.browser`.
- **No new settings or `com.manaflow.cmux` policy keys in slice 1.** The
  cmux mirror is a separate domain with Chrome's names, so the generated MDM
  manifest (docs/mdm) does not change and admins reuse their Chrome payload
  by changing the domain name.
- **Only mandatory URL lists and force-installs count.** Chrome never reads
  them as recommended; a non-forced `URLBlocklist` anyone could write
  (`defaults write`) must not block pages.
- **cmux's own pages and about: are never blocked**, as Chrome exempts its
  internal pages; `*` would otherwise block the new tab page.

## Open / risks

- `chrome_policy_id` makes Chromium honor every Chrome policy, including
  ones that may break cmux features (an `ExtensionInstallBlocklist` of `*`
  also blocks cmux's built-in ad blocker extension). That is the
  organization's decision; documented, not worked around.
- The browser-domain-only URL lists (`com.manaflow.cmux.browser`) reach
  WebKit tabs but not Chromium tabs: Chromium reads only one policy domain.
  Slice 2: push the merged lists into Chromium too (C++ port of
  `BrowserURLFilter` checked in `OnBeforeBrowse`, sharing test vectors like
  `schemas/agent-url-policy/vectors.json`).
- Not yet seen in a running app on a managed Mac: the Mac-mini runs prove
  the reader, mapping, filter and the shim build; a managed-device check
  (install a test profile on a fleet Mac, open chrome://policy in a cmux tab)
  is the next step.

## Later slices

1. Chromium-side enforcement of the browser-domain lists (above).
2. Chrome Enterprise Core enrollment (`CloudManagementEnrollmentToken`
   read from Chrome's domain, `--enable-chrome-browser-cloud-management`),
   behind a `com.manaflow.cmux.browser` key, since it registers cmux in the
   company's admin console.
3. cmux UI gates: DeveloperToolsAvailability, IncognitoModeAvailability,
   DownloadRestrictions on cmux's own entrypoints; an extension list badge
   "Installed by your organization" for force-installed extensions.
4. A "Policies" page in Settings > Browser listing every Chrome policy in
   effect and its source (like chrome://policy).
