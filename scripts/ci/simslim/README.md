# Slim iOS simulators on the fleet (SimSlim)

A stock iOS 26.5 simulator starts ~280 processes and settles at ~4.5 GB of memory
(phys_footprint). Most of that is Siri, Spotlight, widgets, Photos analysis, iCloud and other
background daemons a UI test never touches. [SimSlim](https://github.com/MobAI-App/simslim)
(MIT) writes launchd disable overrides into one simulator's own launchd store, so it boots
without them: ~80 processes and ~1.1 GB, measured on aws-m4pro-8 (iPhone 17 Pro, iOS 26.5,
120 s after boot, 2026-11-15). The host is never changed, only the simulator.

## What the fleet does

`scripts/ci/cmux-next-ios-sim.sh` (the `cmux-ci run --class simulator` step) slims **every
simulator it creates**, before that simulator's first boot:

1. `simslim.sh` fetches the pinned release (`cmux_simslim_version`, sha256 checked) into the
   step's work dir. Nothing is installed on the host.
2. After `simctl create`: `simslim on UDID --preserve-boot-state --profile fleet.json` writes the
   overrides while the simulator is off. Its first real boot is already slim; it never boots stock.
3. After boot, the gate: `simslim doctor UDID --requires push,storekit,universal-links` and
   `simslim verify UDID --profile ...`. A broken required feature, or any drift from the profile,
   **fails the step**: that simulator is not the one the tests asked for.
4. `simslim measure` writes each simulator's footprint to `simslim/LABEL.json` in the artifact
   (`launch` after the app's first screen, `ui-end` after the UI tests), and one line to SUMMARY.md.

If simslim cannot be fetched or is another version, the step runs stock and says
`WARNING stock` in SUMMARY.md. Slimming saves memory; it never blocks a run by being absent.

## The profile: `fleet.json`

SimSlim's default slim set (164 daemons on iOS 26.5), keeping what our app and its tests need:

| Kept | Daemons | Why |
| --- | --- | --- |
| Push notifications | `apsd` | remote push, `simctl push` flows |
| StoreKit / in-app purchase | `storekitd`, `itunesstored`, the three `ams*` daemons, `passd`, `financed` | billing; the purchase sheet needs Wallet and Finance |
| Universal links | `swcd` | `applinks:cmux.com`, `cloud-api.cmux.dev` |

Not slimmed by SimSlim at all (always on): the pasteboard, user notifications, biometrics
(Face ID enrollment), the keyboard, SpringBoard, `sharingd`.

## Opting out, per run

| You need | Run with |
| --- | --- |
| A stock simulator (Spotlight, Photos, iCloud, Siri, widgets, everything) | `CMUX_SIM_FULL=1` |
| Slim, but with some categories or daemons back | `CMUX_SIM_KEEP=photos,search` or `CMUX_SIM_KEEP=com.apple.assetsd` |

On the fleet, pass them with `--env` (hq's controller allows these two for this script):

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
| Widgets, Live Activities, lock-screen posters | `widgets` |
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

## Bumping SimSlim

Change `cmux_simslim_version` and `cmux_simslim_sha256` in `simslim.sh` together (the
`simslim-vX.Y.Z-macos-arm64.tar.gz` asset's digest from `gh release view`), read the release's
changes to the category lists, and rerun the stock-vs-slim UI suites on one simulator host
before it lands.
