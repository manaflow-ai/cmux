# ios-live: the always-on iOS simulator

iPhone simulators run cmux NEXT's iOS app (`cmux-next-ios/`) at all times: several slots on each
reserved ios pool Mac, plus the one person-mirroring iPhone on air-blue. Any agent takes a free slot,
drives it, and puts its own change into it in seconds, without a fleet step, a fresh simulator or a
new sign-in.

```bash
scripts/ios-live/ios-live lease take          # any free slot; prints HOST/SLOT (20 min; `lease beat` extends)
scripts/ios-live/ios-live shot                # screenshot of your slot -> ./ios-live.png
scripts/ios-live/ios-live swift               # your Swift edits, live, no rebuild or relaunch (~2 s)
scripts/ios-live/ios-live swap                # anything else: warm rebuild + reinstall + relaunch
scripts/ios-live/ios-live lease release
```

Run it from your cmux checkout. "Your change" is that checkout against its merge base with
`origin/feat-cmux-next`: commits, staged, unstaged and untracked files under `cmux-next-ios/` and
`scripts/`. Nothing is pushed. Hosts are reached with `reach` (from a lane VM through the lane-gh broker, which relays the slot commands on an `ios` pool host with no whole-host fleet lease: the slot lease is the admission, so a CI step or another lane on the host does not block you; `ios-live` sets `REACH_AUTO_LEASE=0` so reach never takes the host); `ios-live help` lists every command.

The broker relay takes a command of at most 16384 bytes and carries no stdin, so no command carries
host.sh. The client names a commit on origin that has its host.sh (HEAD when it is pushed, else the
merge base with `origin/feat-cmux-next`), and the host reads host.sh at that commit from the fleet's
git mirror (else fetches that one commit) and caches it as `~/ios-live/bin/SHA/host.sh`. An
unpushed host.sh edit is not used, and stderr says so: push it to try it. A `swift` or `swap` patch
rides in the command, so it must fit there (a diff of about 11 KB); a bigger one is refused with
its size: commit and push it, then `ios-live up SHA`.

## Slots

Leo, 2026-11-25: "he needs to be able to test on his phone, as well as have his agents do the
simulator... always-on simulators are capable of having code changes reflect fast if they stay on".
One device with one driver made agents queue, so the default is slots:

- `IOS_LIVE_HOSTS` (default `aws-m4pro-1,aws-m4pro-7,cmux25,cmux26,cmux27,cmux28,cmux29,cmux30`, the reserved ios pool) each carry
  `IOS_LIVE_SLOTS_PER_HOST` (default 3) iPhones, `cmux-ios-live-1..N`.
- `ios-live lease take` holds the first free slot on any host (your own first, so a second take
  renews it) and prints `HOST/SLOT`. Every other command then drives that slot. The client
  remembers it in `~/.cache/ios-live/held-OWNER`.
- `ios-live slots` lists every slot, its base and its holder, and how many are free.
- `ios-live lease release` puts the slot back at `origin/feat-cmux-next` with no patch (`ios-live up`)
  and frees it. `lease release --erase` erases the device first: use it only if you changed its
  state (sign-in, settings, data).
- `IOS_LIVE_AT=HOST/SLOT` looks at a slot you do not hold (`status`, `shot`, `tree`, `log`).

Each slot is `~/ios-live/slots/N` on its host, with the layout below: its own checkout,
DerivedData, `simctl` device set, lease and state, so two agents' builds never share a tree. The
pinned xcodegen and the synced FFI are shared. A slot's device boots headless, is slimmed once
before its first boot with the fleet's pinned `simslim` when the host has it (keeping push and
universal links), and runs with Reduce Motion on and UIKit animations sped up. Slot apps run the
DEBUG default, the development project: sign in with the `agent` profile
(`cmux_dev_secrets_load --profile agent`), never a person's account. No slot has a `launch.env`
unless an agent writes one for its own test.

The person-mirroring iPhone stays as it was: set `IOS_LIVE_HOST=air-blue` and leave
`IOS_LIVE_HOSTS` unset, and every command behaves exactly as before slots (one device,
`cmux-ios-live`, one lease).

## Person slots

Leo, 2026-11-25: "the bigger win possible for aziz is a persistent one that him and his agents can
work against". A person slot is one simulator for one person and their agents. It never lapses, is
never reset on release and is never handed to anyone else:

```bash
scripts/ios-live/ios-live person create aziz          # on the least-loaded of IOS_LIVE_HOSTS (or name a HOST)
IOS_LIVE_PERSON=aziz scripts/ios-live/ios-live swift  # or: ios-live --person aziz swift
scripts/ios-live/ios-live people                      # every person slot: host, base, state, RSS, restarts
```

- It lives at `~/ios-live/people/NAME` on its host, with the same layout as a slot, and its device
  is `cmux-ios-live-NAME`. The client remembers the host in `~/.cache/ios-live/person-NAME`.
- Owners `NAME` and `NAME/*` drive it (the client makes the owner `NAME/HOST/session` for you);
  any other owner is refused. There is no lease: commands that change it (`swift`, `swap`, `up`,
  `erase`, `relaunch`, `undo`, `tap`, `type`) wait in turn on a per-slot lock
  (`lease/drive.lock`), so two agents' swaps run one after the other, never into each other.
- `lease release` does nothing to it. `erase` is the only thing that wipes its device state.

## Supervision

`host.sh supervise` runs every 15 s from a per-user launchd agent
(`~/Library/LaunchAgents/com.cmux.ios-live.supervise.plist`, installed by `person create` or
`host.sh supervise-install`; the agent runs its own copy, `~/ios-live/bin/supervise-host.sh`). It
looks after every person slot and every held shared slot, skipping any slot whose drive lock is
held (a swap in progress):

- **Device not Booted**: boot it; if CoreSimulator wedges, shut it down and boot it; as a last
  resort, kill that device's own `launchd_sim` process tree and boot. It never touches another
  device and never quits Simulator.
- **App not running**: relaunch it with the slot's launch environment, then re-apply the newest
  live code patch (`swift` patches are cumulative, kept in `live-patches/`), so a crash does not
  lose your edits. `swap`, `up` and `undo --all` clear that stack.
- It never erases a device.
- Each restart is recorded in `state.json` `restarts` (time, cause, what it did, ms to back);
  `ios-live status` shows the last few and the device's RSS (its `launchd_sim` tree). Memory per
  device is bounded by the slimmed device.

## Which command

| Change | Command | Edit to visible |
|---|---|---|
| Inside existing functions, computed properties, SwiftUI `body`s | `ios-live swift` | ~5 s from your checkout (on the host: ~2 s) |
| Anything else: stored properties, new files, `project.yml`, resources | `ios-live swap` | warm rebuild (p50 15.9 s on a fleet M4 Pro) |
| The Rust FFI (`cmux-next-ios/rust`) | `ios-live swap` | FFI rebuild first (minutes); a laptop host takes it from `ios-live ffi-sync FLEET_HOST` |

Before this, a change reached a simulator only through a fleet step
(`cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh`). That step waited 7.9 min
in the queue at the median (26 min at p90), built for 287 s, and sent back one screenshot from a
simulator it then deleted (the controller's last 88 iOS simulator steps, 2026-11-16/17).

Measured 2026-11-17, a SwiftUI text edit run from a cosmic-gray checkout, timed to the app's redraw and
checked in a screenshot:
- `ios-live swift` to air-blue (iOS 27.2, Xcode 27.2): p50 4.9 s (4.0 to 5.5 s, 6 edits). The patch
  compiles and links on the host in 1.7 to 2.7 s; the rest is the diff and one `reach` round trip.
- The same edits to aws-m4pro-8: p50 4.1 s (3.9 to 9.9 s).
- The first live code build of a new host: 262 s on air-blue, 198 s on aws-m4pro-8.

`swift` is the live code of `docs/cmux-next/live-code.md` (`scripts/live-code/ios-sim.sh`). It
refuses a change it can't apply, names the functions involved, and leaves the app running; use
`swap` for that change. `ios-live undo [--all]` takes back live patches.

## Rules

- **One driver per device** (a slot, or air-blue's iPhone). Anything that changes or touches the app (`swift`, `swap`, `up`, `relaunch`,
  `tap`, `type`, `undo`) needs the lease. Looking at it (`status`, `shot`, `tree`, `log`) does not.
  The lease names you and lapses on its own. The name is `IOS_LIVE_OWNER` when set, else
  `HOST/SESSION/CHECKOUT` (the Claude Code or Codex session id), else `HOST/CHECKOUT-TOKEN` with the
  token kept in the checkout's git dir (`ios-live-owner`): the same on every call, so a lease taken in
  one shell holds in the next. `ios-live whoami` prints it.
- **Read-mostly.** The live app is signed in to the person's own account and paired with their Macs:
  it is their sessions you see. Never send a message, answer a prompt or approve anything in a
  session it shows. A test that needs to send makes its own scratch session and sends only there.
- **Leave it running.** End on a state someone else can use: `ios-live up` puts it back at
  `origin/feat-cmux-next` with no patch. Never shut down or delete the `cmux-ios-live` device.

## On the host

`~/ios-live` holds everything (`scripts/ios-live/host.sh` explains the layout):
- one checkout;
- the live code build with its warm DerivedData;
- a `simctl` device set with one iPhone named `cmux-ios-live`;
- `launch.env`, the app's launch environment;
- the lease;
- `state.json`, with the base, the patch and the last timings.

Every build is incremental and runs `-jobs 4`. On a laptop host, the machine's guard allows only
these builds (cmuxterm-hq `tools/local-build-guards`, `install.py --ios-live`).

### Mirroring a person's Macs

The phone admits only a Mac signed in to its own account (`cmux-next-ios/PROTOCOL.md`, Admission).
The live app runs in DEBUG, which signs in to the development project by default. For a person's
production Macs, `launch.env` holds:

```
CMUX_MOBILE_STACK_ENVIRONMENT=production
CMUX_MOBILE_API_BASE=https://mobile-api.cmux.dev
CMUX_MOBILE_CLOUD_API_BASE=https://cloud-api.cmux.dev
```

That person signs in once, in the simulator window. The session stays in the simulator's
keychain through every `swap` and relaunch. Each of their Macs then asks once whether to allow
the new phone. Agents never type anyone's credentials.

### Setting up a host

1. Install one iOS simulator runtime: `xcodebuild -downloadPlatform iOS`.
2. Copy the FFI, unless the host has Rust iOS targets: `ios-live ffi-sync FLEET_HOST`.
3. `ios-live lease take && ios-live up`. The first build is cold, about 4 min of app build plus the FFI.
