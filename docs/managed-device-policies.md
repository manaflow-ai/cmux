# Managed device policies (MDM)

cmux supports MDM-enforceable policies for managed Macs. Administrators
deliver them as **forced preference values** through a macOS configuration
profile (a "Custom Settings" / `com.apple.ManagedClient.preferences`
payload). Forced values are tier 0: they win over environment variables,
user settings, `~/.config/cmux/cmux.json` imports, and built-in defaults,
and they cannot be changed from inside the app — the Settings UI shows the
control as "Managed by your organization", the command palette hides the
matching commands, and the `cmux` CLI refuses with a managed-policy error.

## Payload domain

Target the preference domain:

```text
com.cmuxterm.app
```

This is the release app's bundle identifier. Channel builds (debug,
nightly, rc, staging) run under their own bundle identifiers but also honor
profiles targeting `com.cmuxterm.app`, so one profile governs every
channel. A profile may additionally target a channel's own domain (for
example `com.cmuxterm.app.nightly`); a value forced in the app's own
domain wins over the release-domain fallback.

## Policy keys

| Key | Type | Default | Behavior when forced to `true` |
| --- | --- | --- | --- |
| `DisableEmbeddedBrowser` | Boolean | `false` | Disables every embedded-browser surface: browser panes and tabs, terminal-link interception, browser creation from automation/CLI, saved and `cmux.json` layouts, and session restore. Live browser panes are closed when the policy activates. Links open in the system default browser instead. WebKit-based local viewers that ride the same gate (the diff viewer, agent-chat pane, in-app upgrade pages) are also unavailable. The Mac stops advertising browser capabilities to the iOS app. |
| `DisableRemoteControl` | Boolean | `false` | Disables the Mac acting as a remote view/control host for the cmux iOS companion app: the Iroh host runtime (including its local-network advertisement), the legacy TCP pairing listener, connection admission, and device pairing. Live phone connections are closed when the policy activates, the app reports `pairingEnabled=false` to the pairing trust broker so the backend refuses to mint new pair grants, local attach-ticket minting refuses, and relayed phone replies (the cloud-parked inline notification replies) are no longer typed into terminals. Outbound-only notification forwarding to an already-provisioned phone, Sparkle updates, the local automation Unix socket, and Mac-as-client SSH remain unaffected. |
| `DisableDeviceDiscovery` | Boolean | `false` | Disables discovery of other Macs in My Devices. It does not disable this Mac from accepting incoming sessions; use `DisableIncomingDeviceAccess` for that, or `DisableRemoteControl` for the broad host ban. A forced value wins over the local discovery preference and is applied live. |
| `DisableIncomingDeviceAccess` | Boolean | `false` | Prevents this Mac from advertising or accepting incoming Mac and iOS sessions while leaving outbound Mac discovery available. Live incoming sessions are closed and the host withdraws its discoverability state; the local toggle cannot override the forced policy. `DisableRemoteControl` and `DisableIrohNetworking` remain broader bans. |
| `DisableCloud` | Boolean | `false` | Disables cmux Cloud Machines and cmux-managed private-network access. Cloud UI (the right-sidebar Cloud tab, Settings, command palette, title-bar and new-workspace entries), session restore of Cloud workspaces, Cloud VM service calls (create, open, attach, exec, SSH, desktop, ports, publications, Cloud remotes), the Cloud surface registry, and Cloud VM socket/CLI operations are unavailable and fail closed with a managed-policy error (socket code `cloud_disabled`). The Cloud control-plane verbs that share that backend (`remotes.*`, `aiAccounts.*` including credential upload, `coderouter.*`, and `workspace.cloud_vm_*`), the `cmux vm-pty-connect` direct PTY dial, the surface-tab-bar Cloud button, and the `cmux.cloudvm` `cmux.json` action fail closed the same way. The app does not enroll, start, or reconnect its private-network tunnel: `cmux vpn up` and implicit Cloud tunnel use fail closed, while `cmux vpn status`, `cmux vpn down`, and `cmux vpn revoke` remain available for cleanup. When the policy activates mid-session, live Cloud workspaces, providers, and private-network links are torn down and the managed VPN configuration is removed. Local terminals, local automation, and ordinary user-configured SSH remain available. |
| `DisableRemoteConnections` | Boolean | `false` | Disables cmux-created remote connections: SSH, Mosh, and remote tmux sessions, plus the remote registry, from every entry point (command palette, menus, `cmux` CLI, socket automation, and session restore). The socket refuses with `remote_connections_disabled`, `ssh://` links cmux is asked to open are refused up front, and a profile pushed mid-session disconnects every live cmux-created remote workspace and remote tmux mirror (a retained configuration cannot redial, and the wake-from-sleep re-arm is skipped). Cloud Machines attach over the same mechanism, so this key blocks them too; use `DisableCloud` to disable Cloud as a product. Terminals on this Mac are unaffected, and a user's own `ssh` typed into a shell is deliberately out of scope — this control governs connections cmux creates, not the shell. |
| `DisableFileTransfer` | Boolean | `false` | Disables cmux-mediated file transfer: drag-and-drop and pasted-image uploads into a remote terminal (both the workspace remote session and a detected `ssh` session, including a configured `terminal.uploadCommands` custom command), remote-file previews in the SSH file explorer, phone↔Mac transfers over the iOS app (attachment upload, artifact and changed-file fetch, image paste; RPC code `file_transfer_disabled`), and `cmux vm push` / `cmux vm pull`. A refused drop or paste shows the policy message. Local drops into local terminals still work. A user's own `scp` or `rsync` typed into a shell is deliberately out of scope. |
| `DisableIrohNetworking` | Boolean | `false` | Disables cmux-managed Iroh networking: the host runtime never activates, so no endpoint is created, no relay traffic flows, and no routes are published. Local terminal work, the local automation socket, and ordinary SSH are unaffected. `DisableRemoteControl` disables the Mac's role as an iOS remote-control host; this key disables the transport itself. Settings → Networking shows the managed state and locks its controls. |
| `DisableTelemetry` | Boolean | `false` | Disables analytics and crash reporting (PostHog, Sentry) and the remote feature-flag fetch; all three carry the install's anonymous id off the Mac, and flags then use their built-in defaults. Read once at launch, like the user opt-in it overrides, so a profile pushed mid-session applies at the next launch. Settings → App shows the telemetry toggle locked. |
| `DisableAutoUpdate` | Boolean | `false` | Disables Sparkle: no scheduled or launch-time update checks and no downloads, and "Check for Updates…" explains the managed state. Read at launch. Deploy app versions through your MDM instead. |
| `DisableAutomationWebhooks` | Boolean | `false` | Disables the `webhook` action of automation rules (`~/.cmuxterm/automations.json`, `cmux automation`), which posts event payloads with caller-supplied headers to any http(s) URL. The action fails with a managed-policy message in the automation log; `run` and `notify` actions are unaffected. |
| `DisableTLSTrustBypass` | Boolean | `false` | Disables the embedded browser's click-through on certificate errors: the error page offers no bypass and no earlier 24-hour grant is honored. |
| `DisableComputerUse` | Boolean | `false` | Disables cmux Computer Use: new agent launches never receive the cmux-cua tools, the bundled helper stops (also when the policy is pushed mid-session), and Settings → cmux Computer Use locks the toggle. Lifting the policy re-applies the user's own setting. |
| `DisableCustomSidebars` | Boolean | `false` | Disables interpreted custom sidebars from `~/.config/cmux/sidebars` (user- or agent-authored `.js`/`.swift`/`.json` that can dispatch `cmux(...)` commands): none are listed or mounted, and Settings → Beta Features locks the toggle. |
| `DisableAICredentialUpload` | Boolean | `false` | Disables uploading local AI credentials (Claude/Codex OAuth tokens, Anthropic/OpenAI API keys) to the cmux tenant: `cmux ai-accounts upload` (`aiAccounts.upload`) and `cmux coderouter claude add/update` fail closed at the socket (`ai_credential_upload_disabled`) and inside their clients. Listing and removing accounts still work. Independent of `DisableCloud`, which refuses these families entirely. |
| `SocketControlMode` | String | `cmuxOnly` | Forces the local automation Unix socket to `cmuxOnly` or `off`. A forced value wins over Settings, `cmux.json`, `CMUX_SOCKET_MODE`, and `CMUX_SOCKET_PASSWORD`; Settings locks the picker and shows the effective mode. Existing clients are revoked when the mode changes, including password-authenticated and event-stream clients. |
| `BrowserURLAllowlist` | Array of strings | unset (allow all web origins) | Restricts every embedded-browser top-level navigation to matching URL patterns. Address-bar loads, links, redirects, `window.open`, automation, deep links, and restored panes are checked. A forced empty array denies all external web origins while cmux-owned internal documents (such as `about:blank` and diff pages), localhost, and local files remain available unless the two allow keys below turn them off. See [Browser allowlist](#browser-allowlist). |
| `BrowserAllowLocalhost` | Boolean | `true` | Allow-style key. While `true`, a managed `BrowserURLAllowlist` permits `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and `0.0.0.0` on any HTTP(S) port without a rule, so local development servers keep working. Forced to `false`, loopback origins are blocked in the embedded browser — even ones the list names, and even when no list is forced. |
| `BrowserAllowLocalFiles` | Boolean | `true` | Allow-style key. While `true`, local `file:` documents opened through cmux (the address bar, `cmux browser open`, terminal links, a file dropped onto a browser pane, or a link from another local file) stay available under a managed list. Forced to `false`, local files are blocked whether or not a list is forced. |

Notes:

- `DisableEmbeddedBrowser`, `DisableRemoteControl`, `DisableDeviceDiscovery`,
  `DisableIncomingDeviceAccess`, `DisableCloud`,
  `DisableRemoteConnections`, `DisableFileTransfer`,
  `DisableIrohNetworking`, `DisableTelemetry`, `DisableAutoUpdate`,
  `DisableAutomationWebhooks`, `DisableTLSTrustBypass`, `DisableComputerUse`,
  `DisableCustomSidebars`, and `DisableAICredentialUpload` values must be
  Boolean.
  A Boolean key forced to `false` (or to a non-Boolean value) does not enforce
  the policy, but the key still counts as managed for write-locking purposes.
  `BrowserAllowLocalhost` and `BrowserAllowLocalFiles` are the two allow-style
  keys: only a forced Boolean `false` changes behavior, and a forced `true` or
  non-Boolean value leaves the capability allowed.
  `BrowserURLAllowlist` must be an array of strings; a forced empty array is a
  valid policy that blocks all external web origins.
- `SocketControlMode` is a restrictive enum. The only valid forced strings are
  `cmuxOnly` and `off` (case, hyphen, and underscore normalization is accepted).
  A forced value of another type or a broader mode such as `allowAll` is still
  managed but fails closed to `off`; it never falls back to a password or an
  environment override. Removing the profile restores the user's effective
  setting and environment behavior. A regular `defaults write` of either
  `SocketControlMode` or `socketControlMode` is not an MDM force and cannot
  impersonate this policy.
- Only **forced** (profile-delivered) values are honored as policy. A plain
  `defaults write` of these keys has no effect; this is deliberate, since
  an unmanaged value would not be enforceable anyway.
- `BrowserURLAllowlist` entries are host rules or URL-shaped rules. An exact
  host (`internal.example.com`) matches that host; a wildcard
  (`*.example.com`) matches subdomains; `https://git.example.com` restricts
  the scheme; and `http://localhost:3000` restricts both scheme and port.
  A bare `localhost` entry matches any HTTP(S) port. A managed list does not
  need loopback entries: `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and
  `0.0.0.0` are allowed on any port while `BrowserAllowLocalhost` is not
  forced to `false`. Paths, queries, fragments, credentials, and non-HTTP(S)
  pattern schemes are rejected.
- The same syntax is available to unmanaged users as the `browser.urlAllowlist`
  setting in Settings → Browser or `cmux.json`. Settings shows a suggested
  loopback list (`localhost`, `*.localhost`, `127.0.0.1`, `::1`, `0.0.0.0`,
  and `*.localtest.me`); saving that list opts into the restriction, and
  removing individual entries blocks those origins. An absent or cleared user
  value leaves ordinary browsing unrestricted. A non-empty value containing
  only invalid rules fails closed and is called out in Settings. A forced `BrowserURLAllowlist`
  always wins and locks that editor; an administrator may also force the
  user-level `browserURLAllowlist` key directly, and the importer skips the
  setting while either key is managed.
- Policy changes are applied at app launch, on preference-change
  notifications, whenever the app becomes active, and on a periodic
  re-check (about once a minute) while the app runs — a profile pushed
  mid-session takes effect within roughly a minute even if the user never
  leaves cmux. `DisableTelemetry` and `DisableAutoUpdate` are the two
  launch-time reads: Settings shows their managed state within that minute,
  and the telemetry and updater processes honor them at the next launch.
- `SocketControlMode` uses the same roughly 60-second managed-policy
  re-check. A live mode change rotates the socket authorization generation and
  closes clients admitted under the old mode, including idle connections and
  event subscriptions. The compliance command reads the profile directly and
  never opens the socket merely to report status.

## Lockability

Configuration-profile forced values are locked by macOS itself: no
user-level write (including "Reset All Settings") can change the effective
value, and removing the profile restores normal behavior. cmux additionally
suppresses its own writers: the `cmux.json` importer skips every
profile-forced key, and for the browser, remote-control, and Cloud controls
the Settings UI shows the managed state, the command palette hides the
matching commands, and the CLI refuses with a managed-policy error —
including when an administrator forces the user-level
`browserDisabledOverride` key directly instead of the dedicated policy key.

`DisableEmbeddedBrowser` takes precedence over `BrowserURLAllowlist`: when the
disable policy is forced, no embedded browser surface is created and the URL
allowlist is not consulted. If the disable policy is later removed, the
allowlist becomes effective without requiring a restart.

The capability keys compose rather than override one another: each is a
separate gate, and a capability is unavailable when any key covering it is
forced. `DisableRemoteConnections` therefore also blocks Cloud VM attach (a
cmux-created remote connection) even when `DisableCloud` is absent, and
`DisableRemoteControl` and `DisableIrohNetworking` both stop the iOS host, the
latter by disabling the transport for every purpose. Every `Disable…` key
defaults to `false` and the two `BrowserAllow…` keys default to `true`: an
unmanaged Mac, and a managed Mac whose profile omits the key, behave exactly
as an unmanaged install.

When `DisableRemoteConnections` activates mid-session, live cmux-created
remote workspaces disconnect (their configuration is dropped so no reconnect
affordance can redial), remote tmux mirrors detach and close, and the SSH
control masters cmux opened exit. Remote tmux sessions stay alive on their
hosts; only cmux's connections end.

## Automation socket deployment

Use the minimal profile entry below when the supported automation channel must
remain available only to cmux descendants:

```xml
<key>SocketControlMode</key>
<string>cmuxOnly</string>
```

Set the value to `off` to remove the listener entirely. The forced value is
resolved before Settings, `cmux.json` import/reload, `CMUX_SOCKET_MODE`, and
`CMUX_SOCKET_PASSWORD`; possession of a password never bypasses forced
`cmuxOnly`. A profile update is picked up by the existing 60-second policy
re-check, and the listener revokes all connections from the previous
generation before admitting clients under the new value. This covers idle
clients and event/stream subscriptions as well as ordinary requests.

For administrator compliance, run `cmux socket-status --json`. It reads the
forced preference from `com.cmuxterm.app` (including release-domain inheritance
for tagged builds), reports the effective mode, source, and whether the forced
value was valid, and observes the socket path without connecting. The
`live_enforcement` field is therefore `not_observed`: it distinguishes profile
intent and path state from a claim that a running server applied the value.
The command is still usable when the policy is `off` or cmux is not running.

Install, change, and remove the profile through the MDM's normal Custom
Settings workflow. On removal, cmux returns to the user's existing mode and
environment behavior without requiring a restart. If a malformed value is
deployed, cmux treats it as managed and fails closed to `off`; correct the
profile, then wait for the next re-check or relaunch. These controls govern
cmux's supported local automation channel and do not prevent arbitrary native
code running as the same macOS user.

### Verification matrix

The focused behavior and socket tests exercise the following matrix; the
managed-profile row is the one that requires an isolated MDM test Mac or a
controller-hosted profile lane.

The package tests inject the existing forced-value probe for deterministic
resolution and revocation checks. They do not install a profile on a
maintainer Mac. A real `objectIsForced`/configuration-profile run remains an
explicit controller-hosted verification step; this documentation does not
claim that unit tests alone prove deployed MDM delivery.

| Scenario | Forced `cmuxOnly` | Forced `off` | Expected evidence |
| --- | --- | --- | --- |
| Settings/UserDefaults, imported `cmux.json`, `CMUX_SOCKET_MODE=allowAll`, and password env all conflict | Descendants admitted; outside clients rejected; password is ignored | Listener absent; all clients rejected | `SocketControlSettingsTests`, Settings picker lock, `socket-status --json` |
| Forced value is malformed or broader (`allowAll`, `password`) | Fails closed to `off` and remains managed | Fails closed to `off` and remains managed | Resolver test and status `forced_value_status: invalid` |
| Profile changes while clients, idle sockets, or event streams are live | Old generation revoked before new admissions | All old clients revoked and listener stopped | `SocketControlServerManagedPolicyTests` and generation signal |
| Profile removed, then app restarted | User/defaults and environment behavior returns | User/defaults and environment behavior returns | Resolver removal test plus restart run |
| No profile | Existing user behavior is preserved | Existing user behavior is preserved | Unmanaged regression tests |

## Browser allowlist

`BrowserURLAllowlist` restricts the embedded browser to the sites you list.
Most deployments only need the list of company domains, because a managed
list still permits what never leaves the Mac:

- **localhost** — `localhost`, `*.localhost`, `127.0.0.1`, `::1`, and
  `0.0.0.0` on any HTTP(S) port, so local development servers keep working.
  Force `BrowserAllowLocalhost` to `false` to block loopback origins; then
  list any loopback origin you still want with a port-qualified rule such as
  `http://localhost:3000`.
- **local files** — `file:` documents opened through cmux, dropped onto a
  browser pane, or linked from another local file. Force
  `BrowserAllowLocalFiles` to `false` to block them (with or without a list).

Each entry is a host or an HTTP(S) URL pattern:

```text
git.example.com          # exactly this host, any port, http or https
*.example.com            # every subdomain of example.com (not example.com itself)
https://issues.example.com
http://localhost:3000    # only needed when BrowserAllowLocalhost is false
```

The allowlist governs page navigations (address bar, links, redirects,
`window.open`, automation, deep links, restored panes). It does not filter
subresource requests such as images, scripts, or `fetch`. A blocked
navigation shows an in-page explanation with the blocked origin and the next
step; Settings → Browser shows the effective rules and whether localhost and
local files are allowed; and `cmux browser status --json` reports
`url_allowlist`, `url_allowlist_managed`, `url_allowlist_allows_localhost`,
and `url_allowlist_allows_local_files`.

`DisableCloud` independently gates Cloud Machines and the cmux-managed VPN;
it does not disable local terminals, local automation, or ordinary
user-configured SSH. Removing the policy restores Cloud discovery without a
restart. An MDM policy cannot remove a signed entitlement from an installed
binary: builds that carry the Network Extension entitlement keep it, and
enforcement instead makes the Cloud and VPN capability unreachable at runtime
(no enrollment, start, or reconnect while the policy is forced, and any
existing VPN configuration is removed when the policy activates). Builds
without the entitlement continue to use the existing unavailable-backend path.

## Supported platforms and versions

- macOS 13 (Ventura) and later, matching the cmux system requirements.
- cmux for macOS 1.x builds that include this feature (see the changelog
  entry that shipped it). All release channels honor the release payload
  domain as described above.
- Do not deploy `SocketControlMode` until the installed artifact contains this
  key; this change does not promise a stable or NIGHTLY version before one is
  actually published.
- These are macOS-side controls. The iOS companion app needs no separate
  policy: a Mac with `DisableRemoteControl` enforced refuses admission and
  pairing, so the phone cannot attach to it.

## Sample configuration profile

Deploy via your MDM as a Custom Settings payload for `com.cmuxterm.app`,
or install the profile below manually for testing (System Settings →
General → Device Management). This sample keeps the embedded browser enabled
so the allowlist is exercised; use the `DisableEmbeddedBrowser` policy from the
table above when a full browser disable is desired.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.example.cmux.managed-policies</string>
            <key>PayloadUUID</key>
            <string>6D4A3E9C-1B2F-4C8D-9E0A-5F6B7C8D9E0F</string>
            <key>PayloadDisplayName</key>
            <string>cmux managed policies</string>
            <key>PayloadContent</key>
            <dict>
                <key>com.cmuxterm.app</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>DisableRemoteControl</key>
                                <true/>
                                <key>DisableCloud</key>
                                <true/>
                                <key>DisableRemoteConnections</key>
                                <true/>
                                <key>DisableFileTransfer</key>
                                <true/>
                                <key>DisableIrohNetworking</key>
                                <true/>
                                <key>DisableTelemetry</key>
                                <true/>
                                <key>DisableAutoUpdate</key>
                                <true/>
                                <key>DisableAutomationWebhooks</key>
                                <true/>
                                <key>DisableTLSTrustBypass</key>
                                <true/>
                                <key>DisableComputerUse</key>
                                <true/>
                                <key>DisableCustomSidebars</key>
                                <true/>
                                <key>DisableAICredentialUpload</key>
                                <true/>
                                <key>SocketControlMode</key>
                                <string>cmuxOnly</string>
                                <!-- localhost and local files need no entries;
                                     force BrowserAllowLocalhost / BrowserAllowLocalFiles
                                     to false to block them. -->
                                <key>BrowserURLAllowlist</key>
                                <array>
                                    <string>https://git.example.com</string>
                                    <string>*.example.com</string>
                                </array>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>com.example.cmux.managed-policies.profile</string>
    <key>PayloadUUID</key>
    <string>2A1B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D</string>
    <key>PayloadDisplayName</key>
    <string>cmux Managed Policies</string>
    <key>PayloadScope</key>
    <string>System</string>
</dict>
</plist>
```

## Verifying on a managed Mac

```bash
# Shows the effective (forced) values for the release domain:
defaults read com.cmuxterm.app DisableEmbeddedBrowser
defaults read com.cmuxterm.app DisableRemoteControl
defaults read com.cmuxterm.app DisableCloud
defaults read com.cmuxterm.app DisableRemoteConnections
defaults read com.cmuxterm.app DisableFileTransfer
defaults read com.cmuxterm.app DisableIrohNetworking
defaults read com.cmuxterm.app DisableTelemetry
defaults read com.cmuxterm.app DisableAutoUpdate
defaults read com.cmuxterm.app DisableAutomationWebhooks
defaults read com.cmuxterm.app DisableTLSTrustBypass
defaults read com.cmuxterm.app DisableComputerUse
defaults read com.cmuxterm.app DisableCustomSidebars
defaults read com.cmuxterm.app DisableAICredentialUpload
defaults read com.cmuxterm.app BrowserURLAllowlist
defaults read com.cmuxterm.app BrowserAllowLocalhost     # absent or 1 = allowed
defaults read com.cmuxterm.app BrowserAllowLocalFiles    # absent or 1 = allowed

# The CLI reports browser availability and URL-policy metadata:
cmux browser status --json   # url_allowlist, url_allowlist_managed,
                             # url_allowlist_allows_localhost, url_allowlist_allows_local_files

# Reliable socket-policy compliance check. It works while the app is quit or
# the socket is forced off and never sends a request to the automation socket:
cmux socket-status --json
# Example (no password or token is emitted):
# {
#   "configured_mode" : "allowAll",
#   "effective_mode" : "cmuxOnly",
#   "forced_value_status" : "valid",
#   "live_enforcement" : "not_observed",
#   "managed" : true,
#   "managed_source" : "managed_app_domain",
#   "observation_scope" : "profile_and_socket_path",
#   "policy_key" : "SocketControlMode",
#   "socket_path_state" : "present"
# }
# `live_enforcement` is intentionally not inferred from a separate process
# reading defaults; use the app's own tagged verification run for live socket
# admission evidence. When `SocketControlMode` is `off`, the same command
# reports `socket_path_state: absent` without weakening the policy to answer.

# Cloud verbs are refused with a managed-policy error (socket code
# `cloud_disabled`); `cmux vpn status`, `cmux vpn down`, and `cmux vpn revoke`
# remain available for cleanup:
cmux vm list
cmux vpn up
```

In cmux, Settings → Browser shows the enable toggle disabled with
"Managed by your organization", Settings → Mobile shows "Remote control from
the iOS app is disabled by your organization.", and Settings → Beta Features
shows the Cloud Machines toggle disabled with "Managed by your organization"
while the Cloud settings section and the right-sidebar Cloud tab are hidden.
The telemetry toggle (Settings → App), the Computer Use toggle, and the
Custom Sidebars toggle lock the same way under their keys, and
"Check for Updates…" explains the managed state under `DisableAutoUpdate`.
