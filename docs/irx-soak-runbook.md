# irx soak runbook (tag irx)

One tagged Mac + one isolated simulator, relay-only, 15 minutes engaged.

## Mac (host)

```bash
# 1. Enable irx on the tagged bundle BEFORE launch (temporary dogfood setup).
defaults write com.cmuxterm.app.debug.irx cmux.irx.enabled -bool true
defaults write com.cmuxterm.app.debug.irx cmux.irx.force-relay -bool true

# 2. Launch the tagged Mac app (reload-cloud already downloaded it).
./scripts/reload.sh --tag irx --launch   # or open the DerivedData app

# 3. Verify activation in the journal after sign-in:
tail -f /tmp/cmux-irx-journal-mac-irx.jsonl
# expect: host-runtime configured -> activating -> broker registered ->
#         endpoint bound -> online -> route-published -> active ->
#         accept-loop-started
```

## Simulator (client)

```bash
SIMCTL_CHILD_CMUX_IRX_ENABLED=1 \
SIMCTL_CHILD_CMUX_IRX_FORCE_RELAY=1 \
scripts/mobile-dev-launch.sh --tag irx --agent --ensure-mac \
  --simulator "cmux-dev-irx"
```

The sim app registers its own irx binding, mints a pair grant against the
Mac's binding on first dial, and connects relay-only. Journal:
`simctl get_app_container <udid> <bundle> data` + `Documents/irx-journal.jsonl`.

## Physical INTERNAL journal

For a live view of the iROH journal from the attached cmux INTERNAL phone, run
this from the cmux checkout:

```bash
./scripts/stream-ios-logs.sh
```

The default target is Aziz's iPhone and `dev.cmux.app.internal`. The viewer
subscribes to the `IrxJournal` OSLog NOTICE events, so it does not repeatedly
copy the growing JSONL file and does not relaunch or mutate the app. Press
Ctrl-C to stop. To include recent context before the live stream:

```bash
./scripts/stream-ios-logs.sh --tail-lines 100
```

The viewer resolves the CoreDevice identifier to the USB UDID required by
`idevicesyslog`, then filters by the INTERNAL app's current process ID. This
keeps logs from stale DEV bundles installed on the same phone out of the
default stream. If INTERNAL is still starting, the command waits briefly for
its process; use `--all` only when you intentionally want every cmux process.

The stream uses `idevicesyslog`, available from `brew install libimobiledevice`.

## Soak

```bash
python3 scripts/irx-soak.py --tag irx --udid <udid> --bundle-id <ios-bundle> \
  --minutes 15
```

Open a workspace with a terminal on the phone first; the harness types `date`
every ~30s and screenshots every 60s. PASS criteria are in the script header.
