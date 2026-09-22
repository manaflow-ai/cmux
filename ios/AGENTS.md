# ios/ agent instructions

iOS app-target work in this directory follows `Packages/iOS/AGENTS.md`,
including its Apple Human Interface Guidelines rule. Read it before changing
UI.

For connectivity, auth, lifecycle, workspace or terminal changes, follow
`docs/ios-connectivity-soak.md`. Keep the deterministic workload's actions and
postconditions aligned with the product, and record an affected-workload run
or explain the remaining verification gap in the PR.

The sections below moved here from the repository root `CLAUDE.md`, unchanged. Team dev builds and fleet allocation stay in the root file ("Dev builds on the Mac mini fleet"); nothing here overrides it. Script paths are relative to the repository root.

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

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. Use a provisioned, verified controller recipe for the team simulator dev-build leg, following the current HQ runbook. A macOS CMUX build proves neither iOS compilation nor installation. Do not use `ios/scripts/reload-cloud.sh` while it allocates through maclease; report a missing controller recipe. Standalone contributors may use `ios/scripts/reload.sh --tag <tag>`; with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch clears that tagged session, signs both surfaces into the selected profile, verifies the exact tagged Mac account through `auth status`, then mints the pairing ticket. The iPhone auth gate passes only after the same-account host accepts the phone RPC and emits `mobile.rpc.ready`. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` repeats the Mac-account check, relaunches the phone without credentials, and passes only when persisted phone state reconnects. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## iOS and verification capacity

Team iOS simulator dev builds may use only a provisioned and verified controller
recipe. Do not infer simulator, device archive, signing, XCTest, or GUI support
from the macOS recipe or from an idle worker. Preserve the macOS and iOS exact-SHA
receipts separately. Physical-iPhone signing and installation stay local through
the authenticated install queue; signing credentials do not go to shared Macs.
Hosted CI/CD, including TestFlight and scripted XCUITests, remains on the existing
runners, including Blacksmith. Do not migrate those workflows to the mini fleet.

A missing controller verification recipe is a migration gap, not authorization
to revive maclease or run an unscheduled SSH build. For an explicitly authorized
local simulator verification, use an isolated device, never an existing visible
or user-owned simulator, and keep at most three local simulators booted.

## Cross-tag Mac access for DEV iPhone builds

A DEV iPhone build pairs only with the Mac DEV build sharing its tag. When a task needs
the phone to also see other Mac dev builds (multi-Mac verification, dogfooding another
task's Mac from an existing phone build), grant those tags at runtime through the
same-tag Mac's debug socket instead of rebuilding or re-pairing the phone:

```bash
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags add <mac-tag> [more-tags]
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags list
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags remove <mac-tag>
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags clear
```

The grant set persists on that Mac and on the phone (per phone build tag), pushes live
to a connected phone, and otherwise applies on the phone's next connect. Removing a tag
disconnects and hides that Mac on the phone. Release lanes (`default`, `nightly`, `rc`,
`staging`) are never grantable, and only the phone's exact-tag Mac can change its grant
set. Use this whenever the user asks to let another Mac dev build connect to their
iPhone build; do not mint a shared tag or rebuild the phone for that.

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.
