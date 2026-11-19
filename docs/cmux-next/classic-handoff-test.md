# Test the classic → cmux-next update on your own Mac

This points ONE classic cmux install (stable, `/Applications/cmux.app`) at the handoff TEST feed, so its
normal in-app update installs the cmux-next release candidate. Nobody else is affected: the production
feed is not touched, and no shipped build reads the test feed.

Test feed: `https://github.com/manaflow-ai/cmux-next-handoff-test/releases/latest/download/appcast.xml`
(release `rc9-b116`: cmux-next 1.0.0, build 116, Developer ID signed and notarized; Apple silicon only).

## Switch on

Quit cmux (Cmd+Q). Then run in Terminal.app (not in cmux):

```sh
curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/classic-handoff-rc.sh -o /tmp/classic-handoff-rc.sh
bash /tmp/classic-handoff-rc.sh on
```

Open cmux. The sidebar shows "Update…" (or use cmux > Check for Updates…). Click it, then
"Install and Relaunch".

`on` keeps a full copy of your classic app in `~/Library/Application Support/cmux-handoff-test/`, sets
the test feed in the installed app's `Info.plist`, and signs that copy ad hoc. The re-signing is needed:
with only the edit, Sparkle's installer refuses the app and the update fails ("An error occurred while
starting the installer"). While the switch is on, classic's cmux Cloud tunnel and browser passkeys do not
work, and macOS may ask once for keychain access or a permission. Your data is not changed.

## Switch off

- Before you update: quit cmux, then `bash /tmp/classic-handoff-rc.sh off`. It puts the original,
  Developer ID signed classic app back.
- After you updated and want classic back: quit cmux, then `bash /tmp/classic-handoff-rc.sh back`. It
  downloads classic v0.65.2.2, checks the Developer ID team and Gatekeeper, and keeps the cmux-next app it
  replaces in the same folder. Classic opens its own workspaces again.
- `bash /tmp/classic-handoff-rc.sh status` shows the version, the feed, whether the switch is on, and the
  signature.

## What to check after the update

1. About cmux shows version 1.0.0 (build 116). The app is still `/Applications/cmux.app`.
2. cmux asks "Import your classic cmux workspaces?" with the count of workspaces and browser tabs. After
   Import, a toast says "Workspaces from classic cmux are open." Check your windows, workspaces, groups
   (name, color, collapsed), pins, colors, splits and tab names; terminals open in their folders.
3. The sidebar lists your workspaces. If it shows none, check `"sidebar": {"showProjects": false}` in
   `~/.config/cmux/cmux-next.json` (an earlier nightly-next can leave it; B14 in the runbook).
4. Quit and open again: nothing is made twice.
5. Settings: shortcuts you changed in classic, and keys from `~/.config/cmux/cmux.json` (copied to
   `cmux-next.json` only when that file did not exist yet). Theme and font choices made in classic's
   Settings window do not come over (known gap).
6. Sign-in: your cmux account is still signed in. Browser sign-ins do not come over (known gap).
7. CLI: `cmux` in a terminal is now the cmux-next CLI; classic verbs print a hint (known gap).
8. Permissions: Accessibility, Screen Recording, notifications. Note any macOS prompt, for example
   "Data Access Blocked" (seen on macOS 27).
9. Socket: if you set classic's socket mode (Settings > Automation), cmux-next keeps it (the lab runs
   did not check it).
10. Updates: cmux > Check for Updates says you are up to date. cmux-next reads the production feed again,
    which has only classic 0.65.2.2 (a lower build), so it never offers a downgrade.

Recordings of the lab runs are on the
[rc7-b114](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc7-b114),
[rc8-b115](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc8-b115) and
[rc9-b116](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc9-b116) releases.
