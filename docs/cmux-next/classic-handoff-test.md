# Test the classic → cmux-next update on your own Mac

This points ONE classic cmux install (stable, `/Applications/cmux.app`) at the handoff TEST feed, so its
normal in-app update installs the cmux-next release candidate. Nobody else is affected: the production
feed is not touched, and no shipped build reads the test feed.

Test feed: `https://cdn.cmux.sh/cmux-next-handoff-test/appcast.xml`

## Switch on

Run in Terminal.app (not in cmux, which you will quit):

```sh
curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/classic-handoff-rc.sh -o /tmp/classic-handoff-rc.sh
bash /tmp/classic-handoff-rc.sh on
```

Then quit cmux (Cmd+Q), open it again, and choose Help > Check for Updates. Install and relaunch.

`on` changes only `SUFeedURL` in the app's `Info.plist` and keeps the original byte for byte in
`~/Library/Application Support/cmux-handoff-test/`. While it is on, macOS may ask once for keychain
access, because the app's signature no longer matches its edited `Info.plist`.

## Switch off

- Before you update: `bash /tmp/classic-handoff-rc.sh off` puts the original `Info.plist` back (signature
  valid again). Relaunch cmux.
- After you updated and want classic back: quit cmux, then `bash /tmp/classic-handoff-rc.sh back`. It
  downloads classic v0.65.2.2, checks the Developer ID team and Gatekeeper, and keeps the cmux-next app it
  replaces in the same folder. Classic's data was never changed, so classic opens where you left it.
- `bash /tmp/classic-handoff-rc.sh status` shows the version, the feed and whether the switch is on.

## What to check after the update

1. About cmux shows version 1.0.0 (build 114). The app is still `/Applications/cmux.app`.
2. A toast says what came over from classic. Your windows, workspaces, groups (name, color, collapsed),
   pins, colors, splits and tab names are there; terminals open in their folders.
3. Quit and open again: nothing is made twice.
4. Settings: shortcuts you changed in classic, and keys from `~/.config/cmux/cmux.json` (now copied to
   `cmux-next.json`, when that file did not exist yet). Expect theme and font choices made in classic's
   Settings window to be gone (known gap).
5. Sign-in: your cmux account is still signed in. Browser sign-ins do not come over (known gap).
6. CLI: `cmux` in a terminal is now the cmux-next CLI; classic verbs print a hint (known gap).
7. Permissions: Accessibility, Screen Recording, notifications. Note any macOS prompt you get.
8. Socket: if you had set classic's socket mode (Settings > Automation), cmux-next keeps it. (RC build 114
   predates this fix and still resets it to `automation`.)
9. Updates: Help > Check for Updates says you are up to date (it reads the production feed again, which has
   only classic 0.65.2.2, a lower build, so it never offers a downgrade).

Report anything else in the "cmux-next RC" thread with a screenshot.
