# Managing cmux with your MDM

cmux reads managed settings from the macOS preference domain `com.manaflow.cmux`. Any MDM that can deliver a custom configuration profile can manage it; cmux needs no agent of its own. The key list, types and defaults are in [managed-preferences.md](managed-preferences.md). Forced values lock a setting (Settings shows "Managed by your organization"); non-forced values only replace its default.

Files in this folder:

| File | Use it with |
| --- | --- |
| `cmux-example.mobileconfig` | any MDM that uploads a custom profile |
| `com.manaflow.cmux.json` | Jamf Pro "Application & Custom Settings" (custom schema) |
| `com.manaflow.cmux.plist` | iMazing Profile Editor, ProfileCreator (ProfileManifests format) |
| `com.manaflow.cmux.intune.plist` | Microsoft Intune "Preference file" template |
| `ddm-legacy-profile-declaration.json` | MDMs that send Declarative Device Management declarations |

Menu names below were written from each vendor's public documentation as of 2026-10 and may move; the payload is the same everywhere.

## Jamf Pro

1. Computers > Configuration Profiles > New. Scope it to your Macs.
2. Add the payload "Application & Custom Settings" > External Applications > Add > Custom Schema.
3. Preference domain: `com.manaflow.cmux`. Paste `com.manaflow.cmux.json` as the schema, then set the keys in the generated form.
4. To enroll devices into your cmux team, add `EnrollmentToken` (from console.cmux.dev > Policy > Device enrollment).

Extension attribute (managed state per Mac), script type:

```sh
#!/bin/sh
user=$(stat -f %Su /dev/console)
f="/Users/$user/Library/Application Support/cmux/managed-status.json"
[ -f "$f" ] && /usr/bin/plutil -extract conflicts json -o - "$f" | grep -q '"key"' && echo "<result>conflict</result>" && exit 0
[ -f "$f" ] && echo "<result>applied</result>" || echo "<result>no status</result>"
```

## Kandji (Iru)

Library > Add New > Custom Profile. Upload a `.mobileconfig` built from `cmux-example.mobileconfig` (edit the keys and replace both `PayloadUUID` values). Assign it to a Blueprint. Custom Scripts can read the status file like the Jamf extension attribute.

## Microsoft Intune

Devices > macOS > Configuration > Create > Templates > Preference file. Preference domain name `com.manaflow.cmux`; upload `com.manaflow.cmux.intune.plist` after editing the keys. The preference file template applies to the device channel. Alternatively, Templates > Custom with the `.mobileconfig`.

## Workspace ONE UEM

Resources > Profiles & Baselines > Profiles > Add > macOS > Device Profile > Custom Settings. Paste the inner payload dictionary of `cmux-example.mobileconfig` (the dictionary whose `PayloadType` is `com.manaflow.cmux`).

## Mosyle

Management > Custom Profiles > Add new profile. Upload the `.mobileconfig` and assign it to devices or groups.

## Addigy

Policies > Catalog > MDM Profiles > New > Custom Profile (upload the `.mobileconfig`). Addigy's custom facts can read the status file.

## Fleet

Controls > OS settings > Custom settings > Add profile (the `.mobileconfig`, or the DDM declaration JSON for declaration-based delivery). Query status with osquery (below).

## SimpleMDM, Hexnode, JumpCloud and others

Upload the `.mobileconfig` as a custom configuration profile and assign it. Every MDM that installs configuration profiles works the same way.

## Declarative Device Management

Send a legacy profile declaration (`com.apple.configuration.legacy`) whose `ProfileURL` points at your hosted copy of the profile; see `ddm-legacy-profile-declaration.json`. Whether Apple's app managed configuration declaration applies to third-party macOS apps is not verified; until it is, use the legacy profile declaration.

## Checking what a Mac applied

cmux writes `~/Library/Application Support/cmux/managed-status.json` after every change (NIGHTLY and DEV builds write `managed-status.<bundle id>.json`). It lists the managed keys cmux saw, which ones it applied and from where (`mdm` or `team`), conflicts between your profile and the cmux team policy (the profile wins), the managing team and its policy version. It never contains the value of `EnrollmentToken`.

osquery and Fleet:

```sql
-- Macs where cmux reports a conflict between the MDM profile and the team policy
SELECT u.username, j.key, j.value
FROM users u
JOIN file f ON f.path = u.directory || '/Library/Application Support/cmux/managed-status.json'
JOIN parse_json j ON j.path = f.path
WHERE j.fullkey LIKE 'conflicts/%/key';

-- Policy version each Mac applied
SELECT u.username, j.value AS policy_version
FROM users u
JOIN parse_json j ON j.path = u.directory || '/Library/Application Support/cmux/managed-status.json'
WHERE j.fullkey = 'managing_team/policy_version';
```

The record of compliance for a cmux team is server-side: the cmux dashboard (and its admin API) shows, per device, the policy version it applied, its MDM keys and conflicts.
