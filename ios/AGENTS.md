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

This section is for the classic iPhone app in `ios/`. The cmux-next iPhone app (`cmux-next-ios/`)
has its own hand-off command, new and still under end-to-end verification:
[cmux-next-ios/AGENTS.md](../cmux-next-ios/AGENTS.md#hand-off-command-under-verification).

Every agent report for an app change ends with a hand-off the person can review on their
iPhone, with simulator evidence from the fleet, from one command run at the pushed head:

```bash
ios/scripts/reload.sh --review --tag <task-slug> [--workspace <pr-url>] [--wait <seconds>]
```

Run it before a PR exists if you like: with no PR for the branch, the fleet builds go under the task
workspace `ios-review/<task-slug>`. It refuses (exit 2) in a clone without cmux's git hooks; install them once
per clone with `scripts/install-git-hooks.sh` (every worktree of the clone then runs them).

It does, in order, and fails (non-zero) if any step fails:

1. Builds the same-tag Mac app and the iOS app on the build fleet through hq's iOS installer
   (`build-fleet/ios-reload.py`), installs the Mac app at its Tag Opener path and publishes it to
   HQ. It uses `CMUX_HQ_ROOT` if set, then hq's installed iOS workflow `cmux-ios-dev` (install or
   refresh it with `python3 <cmuxterm-hq main>/scripts/install-ios-workflow.py`), then an hq
   checkout `cmux-ci hq-root` names. On a machine with `cmux-ci` it never builds locally: with no
   installer it stops and prints the install command. Only outside contributors (no `cmux-ci`)
   build locally.
2. Signs and installs the iOS app on **every connected iPhone**, not only the configured default,
   with the authenticated install: signed in with the `personal` profile,
   `scripts/verify-iphone-auth.sh` PASS. Never raw `devicectl`. One phone's failure does not stop
   the others; each gets its own line in the report.
3. Checks the build in a **fleet** simulator, never on the person's Mac: hq's
   `scripts/verify-remote.sh ios --tag <tag> --sign-in agent --record-secs 15` installs the tag's
   fleet iOS build in a throwaway simulator on a fleet worker, signs in with the `agent` profile,
   records it, takes a screenshot, deletes the simulator, and returns the evidence directory.
4. Prints a `Review ready` block: each fleet job's real state (job id; queued with its place and why,
   running, done or failed), the Tag Opener link, the fleet simulator evidence and one line per iPhone.

It waits at most `--wait` seconds (default 1800) for the fleet jobs. Past that it prints the block with the
resume command and exits 75; the jobs keep their place in the queue and the rerun waits on the same jobs (it
never resubmits). It also exits 75 when `cmux-ci status` did not answer and a job left no terminal receipt:
its state is unread, not failed. Exit 76 means another run is already waiting on the tag's jobs: nothing failed,
resume after it exits. Report either as "waiting", with the job ids and the resume command, not as a failure.

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

This file covers the classic iPhone app in `ios/`; `ios/scripts/reload.sh` does not build the cmux-next iPhone app in `cmux-next-ios/`. Any work verified by opening the iOS app installs the build on the user's iPhones (with `--review`, every connected one; see "Finishing a task") and checks it in a fleet simulator. Never stop at simulator-only. A macOS CMUX build proves neither iOS compilation nor installation. Build and install with `ios/scripts/reload.sh --review --tag <tag>` (fleet builds; without `--review` it builds locally, which only outside contributors may do). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. Agents never boot a simulator on the person's Mac (see "Simulators run on the fleet").

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch replaces that tagged session with the selected profile. The iPhone auth gate is the app's own receipt: the app declares `CMUXDogfoodReadiness = app-receipt-v1` in `ios/Config/Info.plist`, and after sign-in it writes a receipt that must match a fresh launch nonce, its client id and the selected account. The iOS app does not pair with the Mac, so no Mac takes part in the gate. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` relaunches the phone without credentials and passes only on a receipt from a restored session. The old Mac gate is gone: the cmux-next Mac app no longer runs the iroh phone listener (`mobile.attach_ticket.create`, `mobile.rpc.ready`), so `--readiness mac-rpc`, `--iroh-release-gate`, `--restore-pairing` and an app without `app-receipt-v1` are refused with exit 2. `--attach` and `--ensure-mac` are accepted and ignored. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build still requires the same-tag Mac dev build. The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## Simulators run on the fleet

Agents never boot, install into or open a simulator on the person's Mac: several
agents' simulators overwhelm it. Check iOS work in a fleet simulator with hq's
`scripts/verify-remote.sh ios --tag <tag> [--sign-in agent] [--record-secs N]` (build
the tag first with `cmux-ci build ios` or `--review`), and attach its screenshot and
recording; `verify-remote.sh capacity` shows the pool. `ios/scripts/reload.sh` without
`--review` still builds a local simulator app: only contributors outside the team, who
have no fleet, may use it, with one isolated device that they shut down afterwards.

## No Mac pairing for DEV iPhone builds

The iOS app in `ios/` does not pair with the Mac, and the cmux-next Mac app no longer
runs the iroh phone listener it would have dialed (its iPhone host serves only cmux on
iPhone in `cmux-next-ios/`), so there are no pairing tickets and no cross-tag grants. Classic cmux's
`cmux-debug-cli.sh mobile compatible-tags` does not exist here. A phone build's tag
only names its bundle id (`dev.cmux.ios.<slug>`) and the same-tag Mac build the reload
scripts keep next to it. Do not mint a shared tag.

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.
