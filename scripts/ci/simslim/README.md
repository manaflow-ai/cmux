# Slim iOS simulators on the fleet (SimSlim)

A stock iOS 26.5 simulator starts ~280 processes and settles at ~4.5 GB of memory
(phys_footprint). Most of that is Siri, Spotlight, widgets, Photos analysis, iCloud and other
background daemons a UI test never touches. [SimSlim](https://github.com/MobAI-App/simslim)
(MIT) writes launchd disable overrides into one simulator's own launchd store, so it boots
without them: ~80 processes and ~1.1 GB, measured on aws-m4pro-8 (iPhone 17 Pro, iOS 26.5,
120 s after boot, 2026-11-15). Only the simulator changes: on the host, simslim writes that one
simulator's overrides file under `/private/var/tmp/com.apple.CoreSimulator.SimDevice.UDID/`.

## What the fleet does

`scripts/ci/cmux-next-ios-sim.sh` (the `cmux-ci run --class simulator` step) slims **every
simulator it creates**, before that simulator's first boot:

1. `simslim.sh` fetches the pinned release (`cmux_simslim_version`, sha256 checked) into the
   step's work dir. Nothing is installed on the host.
2. After `simctl create`: `simslim on UDID --preserve-boot-state --profile fleet.json` writes the
   overrides while the simulator is off, then boots it once to read them back and shuts it down
   (~30 s on an M4 Pro). The step's own boot is then slim. (If a runtime ignores the written
   store, simslim falls back to booting it and disabling live, then rebooting.)
3. A slim simulator is booted before `xcodebuild` and gated: `simslim doctor UDID --requires push,storekit,universal-links` and
   `simslim verify UDID --profile ...`. A broken required feature, or any drift from the profile,
   **fails the step**: that simulator is not the one the tests asked for.
4. `simslim measure` writes each simulator's footprint to `simslim/LABEL.json` in the artifact
   (`launch` after the app's first screen, `ui-end` after the UI tests), and one line to SUMMARY.md.

If simslim cannot be fetched (120 s limit) or is another version, the step runs stock and says
`WARNING stock` in SUMMARY.md. Slimming saves memory; it never blocks a run by being absent.
A stock run boots its test simulators exactly as before SimSlim: `xcodebuild` boots them after
it compiles, so no idle stock simulator waits through a build.

Parallel testing would clone a simulator per worker, and clones start stock (overrides do not
survive `simctl clone`). The step's schemes do not parallelize; SUMMARY.md warns if a run
ever did.

Performance numbers (`chief-live-perf`, `listperf`, `energy`) depend on what else the simulator
runs. The Chief layout heading names the simulators (`slim` or `stock`); compare receipts of
the same kind only, and take a fresh stock baseline rather than an old receipt.

## The profile: `fleet.json`

SimSlim's default slim set (164 daemons on iOS 26.5), keeping what our app and its tests need:

| Kept | Daemons | Why |
| --- | --- | --- |
| Push notifications | `apsd` | remote push, `simctl push` flows |
| StoreKit / in-app purchase | `storekitd`, `itunesstored`, the three `ams*` daemons, `passd`, `financed` | billing; the purchase sheet needs Wallet and Finance |
| Universal links | `swcd` | `applinks:cmux.com`, `cloud-api.cmux.dev` |

Visible on a slim simulator: the Home Screen and lock screen wallpaper is black (the poster
services are off), and system banners such as "Ready for Apple Intelligence" no longer cover the
app at launch. The app itself draws the same.

Measured per variant on aws-m4pro-8 (`measure-matrix.sh`, 120 s settle): stock 278 processes /
4.53 GB; fleet.json 77 / 1.01 GB; keeping photos 1.06, search 1.04, icloud 1.10, siri 1.24,
widgets 2.46, photos+search+icloud 1.11 GB. Five at once: 23.9 GB stock, 4.9 GB slim.

Not slimmed by SimSlim at all (always on): the pasteboard, user notifications, biometrics
(Face ID enrollment), the keyboard, SpringBoard, `sharingd`.

## Opting out, per run

| You need | Run with |
| --- | --- |
| A stock simulator (Spotlight, Photos, iCloud, Siri, widgets, everything) | `CMUX_SIM_FULL=1` |
| Slim, but with some categories or daemons back | `CMUX_SIM_KEEP=photos,search` or `CMUX_SIM_KEEP=com.apple.assetsd` |

On the fleet, pass them with `--env`. The controller allows these two for this script once
manaflow-ai/cmuxterm-hq#11608 is deployed; until then it refuses them:

```bash
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg test --arg ui=DeepLinkUITests --env CMUX_SIM_FULL=1 \
  --artifact artifacts/ios-sim/evidence.zip
```

`CMUX_SIM_KEEP` takes category IDs (`simslim profiles`) and launchd labels, comma-separated; a
word with a dot is a label. A typo fails the step before any simulator boots.

## Which category to keep

| Symptom on a slim simulator | Keep |
| --- | --- |
| Spotlight or Settings search is empty; Files / document picker "Recents" says Content Unavailable | `search` |
| Photos picker empty or stuck, photo library access | `photos` |
| iCloud, Sign in with Apple, Apple Account (`akd`) | `icloud` |
| Siri, speech recognition, dictation (`corespeechd`) | `siri` |
| Widgets, Live Activities, lock-screen posters; the Home Screen wallpaper (slim shows black) | `widgets` (the costly one: 2.46 GB instead of 1.01 GB) |
| Contacts, Calendar, Reminders, Mail pickers | `pim` |
| iMessage, FaceTime, identity services | `messaging` |
| HealthKit, HomeKit | `health` |
| App Intents / Shortcuts indexing (`linkd`), App Clips, VoiceOver voice downloads | `other` |
| Configuration profiles, declarative device management | `mdm` |
| AirDrop, Continuity, Find My | `connectivity` |
| Safari sync, web push | `web` (universal links are already kept) |

`simslim profiles ID` lists one category's daemons; `simslim doctor --list` maps features to
daemons.

## Re-enabling on a simulator that is already running

For a simulator you are holding (a rig, a debugging session), no new run needed:

```bash
simslim enable UDID photos,icloud          # back on now, no reboot
simslim disable UDID photos                # off again, no reboot
simslim on UDID --keep com.apple.assetsd   # re-slim keeping one daemon (reboots)
simslim on UDID --except photos,search     # re-slim keeping whole categories (reboots)
simslim off UDID                           # back to stock (reboots)
simslim status UDID; simslim measure UDID  # what is off; what it costs
```

The step's own simulator lives in a device set of its own: add `--set PATH` (the step's
`.build/ios-sim/sims`). The kit and UI test simulators are in the default set.

## Measuring a host

`measure-matrix.sh OUT [SETTLE_SECONDS] [N]` boots one iPhone per variant (stock, SimSlim's
default, fleet, fleet + one kept category each), lets it settle, and writes `matrix.jsonl`
(processes, phys_footprint, boot and slim seconds, doctor per feature), then N stock and N slim
at once (`density.jsonl`). It is not a controller step: run it on one host you hold with
`build-fleet/fleet-lease take HOST`, with `CMUX_CI_STEP_KEY` set and `CMUX_SIMSLIM_BIN` at the
pinned binary. It uses a device set of its own and deletes it.

## Bumping SimSlim

Change `cmux_simslim_version` and `cmux_simslim_sha256` in `simslim.sh` together (the
`simslim-vX.Y.Z-macos-arm64.tar.gz` asset's digest from `gh release view`), read the release's
changes to the category lists, and rerun the stock-vs-slim UI suites on one simulator host
before it lands.
