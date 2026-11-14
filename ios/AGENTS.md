# ios/ agent instructions

iOS app-target work in this directory follows `Packages/iOS/AGENTS.md`,
including its Apple Human Interface Guidelines rule. Read it before changing
UI.

For connectivity, auth, lifecycle, workspace or terminal changes, follow
`docs/ios-connectivity-soak.md`. Keep the deterministic workload's actions and
postconditions aligned with the product, and record an affected-workload run
or explain the remaining verification gap in the PR.

Script paths are relative to the repository root. Team members: shared build fleet rules for iOS are in cmuxterm-hq.

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

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. A macOS CMUX build proves neither iOS compilation nor installation. Build with `ios/scripts/reload.sh --tag <tag>`; with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch replaces that tagged session with the selected profile. The iPhone auth gate is the app's own receipt: the app declares `CMUXDogfoodReadiness = app-receipt-v1` in `ios/Config/Info.plist`, and after sign-in it writes a receipt that must match a fresh launch nonce, its client id and the selected account. The iOS app does not pair with the Mac, so no Mac takes part in the gate. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` relaunches the phone without credentials and passes only on a receipt from a restored session. The old Mac gate is gone: the cmux-next Mac app no longer runs the iroh phone listener (`mobile.attach_ticket.create`, `mobile.rpc.ready`), so `--readiness mac-rpc`, `--iroh-release-gate`, `--restore-pairing` and an app without `app-receipt-v1` are refused with exit 2. `--attach` and `--ensure-mac` are accepted and ignored. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build still requires the same-tag Mac dev build. The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## Local simulators

For local simulator verification, use an isolated device, never an existing
visible or user-owned simulator, and keep at most three local simulators booted.

## No Mac pairing for DEV iPhone builds

The iOS app in `ios/` does not pair with the Mac, and the cmux-next Mac app no longer
runs the iroh phone listener it would have dialed (its iPhone host serves only cmux on
iPhone in `cmux-next-ios/`), so there are no pairing tickets and no cross-tag grants. Classic cmux's
`cmux-debug-cli.sh mobile compatible-tags` does not exist here. A phone build's tag
only names its bundle id (`dev.cmux.ios.<slug>`) and the same-tag Mac build the reload
scripts keep next to it. Do not mint a shared tag.

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.
