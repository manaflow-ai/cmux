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
nightly, staging) run under their own bundle identifiers but also honor
profiles targeting `com.cmuxterm.app`, so one profile governs every
channel. A profile may additionally target a channel's own domain (for
example `com.cmuxterm.app.nightly`); a value forced in the app's own
domain wins over the release-domain fallback.

## Policy keys

| Key | Type | Default | Behavior when forced to `true` |
| --- | --- | --- | --- |
| `DisableEmbeddedBrowser` | Boolean | `false` | Disables every embedded-browser surface: browser panes and tabs, terminal-link interception, browser creation from automation/CLI, saved and `cmux.json` layouts, and session restore. Live browser panes are closed when the policy activates. Links open in the system default browser instead. WebKit-based local viewers that ride the same gate (the diff viewer, agent-chat pane, in-app upgrade pages) are also unavailable. The Mac stops advertising browser capabilities to the iOS app. |
| `DisableRemoteControl` | Boolean | `false` | Disables the Mac acting as a remote view/control host for the cmux iOS companion app: the Iroh host runtime (including its local-network advertisement), the legacy TCP pairing listener, connection admission, and device pairing. Live phone connections are closed when the policy activates, and the app reports `pairingEnabled=false` to the pairing trust broker so the backend refuses to mint new pair grants. Outbound-only notification forwarding to an already-provisioned phone, Sparkle updates, the local automation Unix socket, and Mac-as-client SSH remain unaffected. |

Notes:

- Values must be Boolean. A key forced to `false` (or to a non-Boolean
  value) does not enforce the policy, but the key still counts as managed
  for write-locking purposes.
- Only **forced** (profile-delivered) values are honored as policy. A plain
  `defaults write` of these keys has no effect; this is deliberate, since
  an unmanaged value would not be enforceable anyway.
- Policy changes are applied at app launch, on preference-change
  notifications, whenever the app becomes active, and on a periodic
  re-check (about once a minute) while the app runs — a profile pushed
  mid-session takes effect within roughly a minute even if the user never
  leaves cmux.

## Lockability

Configuration-profile forced values are locked by macOS itself: no
user-level write (including "Reset All Settings") can change the effective
value, and removing the profile restores normal behavior. cmux additionally
suppresses its own writers: the `cmux.json` importer skips every
profile-forced key, and for the browser and remote-control controls the
Settings UI shows the managed state, the command palette hides the matching
commands, and the CLI refuses with a managed-policy error — including when
an administrator forces the user-level `browserDisabledOverride` key
directly instead of the dedicated policy key.

## Supported platforms and versions

- macOS 14 (Sonoma) and later, matching the cmux system requirements.
- cmux for macOS 1.x builds that include this feature (see the changelog
  entry that shipped it). All release channels honor the release payload
  domain as described above.
- These are macOS-side controls. The iOS companion app needs no separate
  policy: a Mac with `DisableRemoteControl` enforced refuses admission and
  pairing, so the phone cannot attach to it.

## Sample configuration profile

Deploy via your MDM as a Custom Settings payload for `com.cmuxterm.app`,
or install the profile below manually for testing (System Settings →
General → Device Management).

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
                                <key>DisableEmbeddedBrowser</key>
                                <true/>
                                <key>DisableRemoteControl</key>
                                <true/>
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

# The CLI reports the managed state:
cmux browser status --json   # {"enabled": false, "managed": true, ...}
```

In cmux, Settings → Browser shows the enable toggle disabled with
"Managed by your organization", and Settings → Mobile shows "Remote
control from the iOS app is disabled by your organization."
