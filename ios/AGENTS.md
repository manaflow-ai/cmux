# ios/ agent instructions

iOS app-target work in this directory follows `Packages/iOS/AGENTS.md`,
including its Apple Human Interface Guidelines rule. Read it before changing
UI.

For connectivity, auth, lifecycle, workspace or terminal changes, follow
`docs/ios-connectivity-soak.md`. Keep the deterministic workload's actions and
postconditions aligned with the product, and record an affected-workload run
or explain the remaining verification gap in the PR.

Script paths are relative to the repository root. Team members: shared build fleet rules for iOS are in cmuxterm-hq.

## Finishing a task

Every agent report for an app change ends with a hand-off the person can review on the
Simulator and the iPhone, from one command run at the pushed head:

```bash
ios/scripts/reload.sh --review --tag <task-slug> [--workspace <pr-url>]
```

It does, in order, and fails (non-zero) if any step fails:

1. Builds the same-tag Mac app and the iOS app on the build fleet through hq's
   `build-fleet/ios-reload.py` (found through `CMUX_HQ_ROOT`, then `cmux-ci hq-root`), installs
   the Mac app at its Tag Opener path and publishes it to HQ. Without an hq checkout it builds
   locally, which is only for contributors outside the team.
2. Signs and installs the iOS app on **every connected iPhone**, not only the configured default,
   with the authenticated install: signed in with the `personal` profile,
   `scripts/verify-iphone-auth.sh` PASS. Never raw `devicectl`. One phone's failure does not stop
   the others; each gets its own line in the report.
3. Boots the tag's isolated simulator `cmux-dev-<slug>` on the person's Mac (at most three booted),
   opens its window in the background (`open -g`, never taking focus) and launches the app signed
   in, ready to review. Xcode 26 and earlier open it in Simulator.app; Xcode 27 has no
   Simulator.app, so it opens in DeviceHub (`devices://device/open?id=<udid>`). Both are supported. This review simulator signs in with the `personal`
   profile, the phone's account, so it cannot replace the phone's pairing with the tagged Mac;
   agent-driven Simulator verification still uses `agent`.
4. Runs `verify-iphone-auth.sh` again on each phone, so every phone is proven signed in after the
   simulator launch, and prints a `Review ready` block with the Tag Opener link, the simulator
   state and one line per iPhone.

### New phones

Connecting a new phone is welcome: `--review` treats every connected, paired iPhone as a target.
The first time it sees a phone, it adds it to `~/.config/cmux/iphone-device-ids`
(`<udid>\t<name>\t<model>`), installs on it, and makes it the default
(`~/.config/cmux/iphone-device-id`) when none is set. A default phone that is not connected is
listed as "not connected" in the report. To get a new phone ready:

1. Pair it with this Mac once (unlock it, tap Trust) and turn on Developer Mode.
2. Only for fleet-built dev apps (the `--review` default for team members): put the phone on the
   team tailnet. The cmux-next iOS app itself does not need Tailscale, but hq's fleet bakes its
   tagged dev backend into `CMUXApiBaseURL`, and that `*.ts.net` host is reachable only on the
   tailnet. Off the tailnet the app installs but never signs in, and the gate fails with "never
   published a signed-in app receipt". Locally built device apps use the public
   `cmux-staging.vercel.app` API instead.
3. Run `--review` again; the report shows the phone's own line.

A phone is always connected. No connected phone, a locked phone, a queued install or a failed auth
gate is a blocker: report its `FAIL:` line and the retry command. Do not skip the phone, fall back
to `--simulator-only` or pass `--no-sign-in`/`--no-attach`/`--no-setup`. Rerunning the same command
resumes the saved fleet jobs without resubmitting. Copy the `Review ready` block into the report
(format in the root [AGENTS.md](../AGENTS.md#finishing-a-task)).

## Keep cheap iOS-only regressions in `ios/tests/`

Linux-runnable regressions that only inspect iOS scripts/configuration belong in
`ios/tests/` and should be wired into a Linux guard lane. Do not put new
iOS-only Node tests under `scripts/lib/`: the main CI change router treats that
tree as macOS-relevant, which can queue an unrelated macOS compile-admission
build. Tests that genuinely need Xcode, a simulator, or a physical device stay
in the corresponding iOS verification lane.

## iOS UI follows the Apple HIG

`Packages/iOS/AGENTS.md` requires consulting the Apple Human Interface
Guidelines for any iOS UI change and citing the page in the PR. It applies to
`Packages/iOS/` and `ios/`.

## iOS builds open on the iPhone by default

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhones (with `--review`, every connected one; see "Finishing a task"). Never stop at simulator-only. A macOS CMUX build proves neither iOS compilation nor installation. Build with `ios/scripts/reload.sh --tag <tag>`; with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch clears that tagged session, signs both surfaces into the selected profile, verifies the exact tagged Mac account through `auth status`, then mints the pairing ticket. The iPhone auth gate passes only after the same-account host accepts the phone RPC and emits `mobile.rpc.ready`. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` repeats the Mac-account check, relaunches the phone without credentials, and passes only when persisted phone state reconnects. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## Local simulators

For local simulator verification, use an isolated device, never an existing
visible or user-owned simulator, and keep at most three local simulators booted.

## Cross-tag Mac access for DEV iPhone builds

A DEV iPhone build pairs only with the Mac DEV build sharing its tag. Classic cmux
granted other Mac tags at runtime with `cmux-debug-cli.sh mobile compatible-tags`;
cmux-next has no `mobile` CLI scope and its Mac host reports an empty
`mac_compatible_mac_tags` list (`MobileCompatHostInfo.swift`), so that grant does not
exist here yet. To dogfood another Mac build from a phone, build the phone with that
Mac's tag. Do not mint a shared tag.

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.
