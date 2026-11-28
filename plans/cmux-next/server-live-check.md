# cmux next: server live check (Login Items approval, helper XPC, Stop Serving)

The pmset changes run only on a server Mac, never on the laptop.

Status: ready for the first signed nightly-next build that contains 1eeaa5bb269 (app server status,
helper fixes, Stop Serving). Lane 10. Run on the Mac that will be the server (the Mac mini), never on
a developer laptop: the fixes change `pmset` power settings.

## Preconditions (check before you ask Lawrence)

The signed build must contain all three. Without them the steps below stop early:
- the server stack (cmux-server, cmux-host, process roles; in the window queue): without it the
  bundled `cmux` has no `cmux host run` and no `cmux server status`, so the panel says the server is
  not available, no health alert shows, and there is no Fix button (no helper round trip). The
  agent plist below is bundled anyway: until the stack ships, a registered agent exits non-zero
  and launchd restarts it (at most once per 10 s), so **Make This Mac a Server** refuses with "The
  server software is not ready in this build yet." until Debug Settings > Server > **Allow server
  agent** (`server.agent.allowRegister`, off by default) is on. Stop Serving works with it off;
- the server LaunchAgent plist `Contents/Library/LaunchAgents/com.cmux.server.plist`, now written by
  `scripts/cmux-next/bundle-server-helper.sh` (Xcode phase "Bundle server helper", and `--stamp`
  again at signing from the final bundle id) in every DEV and NIGHTLY build that bundles
  `Contents/Resources/bin/cmux`; stable builds drop it. Label `<bundle id>.server`, `BundleProgram`
  `Contents/Resources/bin/cmux`, arguments `host run`, `RunAtLoad`, `KeepAlive`
  {`SuccessfulExit`: false}, `ThrottleInterval` 10, `ProcessType` Standard, no environment and no
  log path (`cmux host run` writes its own log). Without it **Make This Mac a Server** answers "This build does not include the server software yet.";
- the helper (same script: `Contents/Library/LaunchDaemons/com.cmux.server.helper.plist` and
  `Contents/Resources/libexec/cmux-server-helper`), signed with the app's Team ID: release signing
  (`scripts/sign-cmux-bundle.sh` through `scripts/sign-cmux-bundle-helpers.sh`) signs every libexec
  helper with the Developer ID identity, the helper with the hardened runtime, a timestamp, the
  identifier `cmux-server-helper` and no entitlements. Both plists are sealed by the app signature
  and notarized with the app.
Check: `ls "<app>/Contents/Library/LaunchAgents" "<app>/Contents/Library/LaunchDaemons"` and
`plutil -extract Label raw "<app>/Contents/Library/LaunchAgents/com.cmux.server.plist"` (use that
label in B.1).

## A. Steps for Lawrence (one time, on the server Mac)

1. Open the signed cmux next build. Open the command palette and run **Make This Mac a Server**.
   - You see: a server icon (a rack) in the menu bar. If macOS asks, it shows
     "Allow cmux in System Settings > Login Items, then try again." in cmux.
2. Open **System Settings > General > Login Items & Extensions**. Under **Allow in the Background**,
   find the entry with the cmux build's name (for example "cmux NIGHTLY"; the item can show
   "2 items" when the app has the server agent and the helper). Turn its switch **on**. If macOS asks
   for your password or Touch ID, give it.
   - You see: the switch is on. In cmux, the menu bar panel shows the server status (no
     "not available" text).
3. In the cmux menu bar panel, open **Server Health**. On an alert "System sleep on AC is enabled",
   click **Keep Awake on Power** (the first time, macOS can ask again to allow the helper; allow it).
   - You see: the alert goes away after the status reads again. Then tell the lane: "approved".
4. Undo (any time): in the palette run **Stop Serving**.
   - You see: the menu bar icon goes away. cmux puts the power settings back first, then removes the
     server agent and the helper. If the helper still waits for approval and a fix was applied, cmux
     shows "Allow cmux in System Settings > Login Items, then try again." and keeps the helper until
     the settings are back.
   - Full manual undo: System Settings > General > Login Items & Extensions > Allow in the
     Background > turn the cmux entry **off**.

## B. Lane live check (after Lawrence says "approved")

Run on the server Mac as Lawrence's user, through SSH from the lane (no GUI automation needed for
the checks below). Replace `<bundle id>` with the build's bundle id
(`defaults read "<app>/Contents/Info" CFBundleIdentifier`). Save every output under
`.cmux-scratch/nx-worker/server-live/<date>/`.

```bash
APP="/Applications/cmux NIGHTLY.app"        # the signed build that was approved
BID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier)
OUT=~/server-live-$(date +%Y%m%dT%H%M%S); mkdir -p "$OUT"

# 1. Before: power settings and registrations (read only).
pmset -g custom                                   > "$OUT/pmset-before.txt"
AGENT=$(plutil -extract Label raw "$APP/Contents/Library/LaunchAgents/com.cmux.server.plist")
launchctl print "gui/$(id -u)/$AGENT"             > "$OUT/agent.txt" 2>&1   # the server LaunchAgent
sudo launchctl print "system/$BID.server-helper"  > "$OUT/helper.txt" 2>&1  # the helper LaunchDaemon (read only)
codesign -dv --verbose=2 "$APP/Contents/Resources/libexec/cmux-server-helper" > "$OUT/helper-sign.txt" 2>&1

# 2. XPC round trip: Lawrence's click in A.3 is the round trip (apply). Capture the result:
pmset -g custom                                   > "$OUT/pmset-after-fix.txt"
diff "$OUT/pmset-before.txt" "$OUT/pmset-after-fix.txt" > "$OUT/pmset-fix.diff"
ls -l "$HOME/Library/Application Support/cmux/server-fix-ledger/" > "$OUT/ledger.txt"
sudo ls -l "/Library/Application Support/cmux/server-helper/" > "$OUT/helper-priors.txt"
log show --last 15m --predicate "process == \"cmux-server-helper\"" > "$OUT/helper-log.txt"

# 3. Unregister: Lawrence runs Stop Serving (A.4). Then:
pmset -g custom                                   > "$OUT/pmset-after-stop.txt"
diff "$OUT/pmset-before.txt" "$OUT/pmset-after-stop.txt" > "$OUT/pmset-stop.diff"   # must be empty
launchctl print "gui/$(id -u)/$AGENT"             > "$OUT/agent-after.txt" 2>&1     # must be "not found"
sudo launchctl print "system/$BID.server-helper"  > "$OUT/helper-after.txt" 2>&1    # must be "not found"
ls -l "$HOME/Library/Application Support/cmux/server-fix-ledger/" > "$OUT/ledger-after.txt"
```

Pass criteria (each one is evidence in the report):
- `helper.txt` shows the LaunchDaemon `<bundle id>.server-helper`, and `helper-sign.txt` shows the
  same Team ID as the app.
- `pmset-fix.diff` shows only the allowlisted keys (`sleep`, `disksleep`, `womp`; `autorestart` only
  if that fix ran) changed to the fix values.
- The ledger file exists with mode 0600 and names the applied fix ids.
- `pmset-stop.diff` is empty (the user's values are back), both registrations are gone, and the
  ledger has no entries.
- `helper-log.txt` has no refusal of the app's connection (the code-signing requirement matched).

The `sudo` commands are read only (`launchctl print`, `ls`). The lane runs them only if Lawrence
allows `sudo` on that Mac for this check; otherwise those lines are UNVERIFIED and the pmset and
ledger evidence carries the check.
