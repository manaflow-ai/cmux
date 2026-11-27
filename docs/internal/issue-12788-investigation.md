# Issue #12788: unresolved post-update hang

Status: no confirmed reproduction, causal diagnosis, or verified fix.

The customer reports an immediately stuck workspace after updating to cmux
0.64.24 (build 104, `f5da007dd`) on macOS 26.6.2, Apple M3 Pro. The issue has
no reproduction steps, process sample, session fixture, or attachment.

## Correction to the initial PR

PR #12800 originally proposed skipping automatic session restore after any
unclean exit and enabling the existing startup file log for stable builds.
Those changes have been withdrawn. There is no evidence tying this report
to restored session state, and changing crash recovery is not justified by
an unspecified post-update hang. The associated policy tests established
neither the customer failure nor responsiveness after the proposed change.

The earlier description of a clean-environment reproduction was incorrect.
The local observations below are inconclusive and must not be used to close
the issue or describe a fix as verified.

## What was actually observed

- The downloaded release DMG matched the appcast size of 225143654 bytes.
  Its SHA-256 was
  `5bda5ca997a9369de45be6e34fe9c6e7b55b44cd42d0779ec6dd14c39b830924`.
  The bundle identified itself as 0.64.24, build 104, with arm64 and x86_64
  executable slices.
- The local host ran macOS 26.4.1, not the reported 26.6.2. The invoking
  shell reported `sysctl.proc_translated=1`.
- One direct launch remained alive before startup logging began. A five-second
  sample contained only `??? (in Rosetta Runtime Routines)`, reported a 244 KB
  footprint, and provided no cmux/AppKit/SwiftUI stack. It does not attribute
  a hang to the application.
- That launch later emitted breadcrumbs through `app.init.delegate.configured`.
  The explicitly native repeat returned exit status 143 (SIGTERM), also after
  reaching that marker. No stack at that boundary established a blocked thread.
- Another stable cmux with the same `com.cmuxterm.app` bundle ID was already
  running. `AppDelegate.observeDuplicateLaunches()` terminates same-ID launches,
  so the attempts were not isolated even with temporary HOME/CFFIXED_USER_HOME.
  The exact sender of SIGTERM was not recorded.
- The attempts passed `-ApplePersistenceIgnoreState YES`.
  `SessionRestorePolicy.shouldAttemptRestore()` rejects explicit arguments
  other than Finder's `-psn_` argument, so these attempts did not exercise
  automatic session replay. Snapshot preparation itself occurs during
  `AppDelegate.configure()`, before `applicationDidFinishLaunching`; the last
  breadcrumb alone cannot exclude that work as a potential stall location.
- The tagged Debug build failed during SwiftPM manifest linking with
  `No space left on device`. No changed app was built or exercised before
  the initial PR was opened. Green general CI checks are not evidence of
  a before/after hang test or customer recovery.

## Evidence needed to validate a fix

1. Use a GUI-ready Mac through the supported controller job system and an
   isolated app identity. Match macOS 26.6.2 where available and record
   OS/hardware differences explicitly. Keep native and translated launch
   results separate. If the controller lacks a validated GUI verification
   recipe, record that gap rather than allocating through retired tooling.
2. Exercise the affected release with a fresh account/profile, then a
   controlled persisted session and an update/relaunch. Do not add launch
   arguments that bypass the restoration path under investigation.
3. Distinguish process existence, socket acceptance, main-thread command
   completion, and actual terminal input/output. A live process or a socket
   path alone does not prove the workspace is interactive.
4. Capture a process sample while the failure is occurring, together with
   launch/update milestones and the session shape. Obtain equivalent
   evidence from the affected customer if the controlled workloads remain
   responsive. Related issues with generic SwiftUI stacks do not establish
   the cause of this report.
5. Once a blocking path is demonstrated, add a behavioral regression that
   fails on the affected implementation, apply the causal fix, and repeat
   the same workload with responsiveness and session-preservation assertions.
   Confirm recovery on the customer's setup when local reproduction remains
   unavailable. Report residual uncertainty rather than implying that an
   unrelated green test verifies the customer failure.

This internal investigation note changes no product UI, CLI help, localized
documentation site, or message catalog.

Any future developer build must use `cmux-ci`, an exact pushed commit, and
the tag `issue-12788-workspace-update-stuck`. Retain the submission and
terminal receipts and wait on the same job ID after a timeout. A successful
app-build receipt does not establish GUI-test readiness or reproduce this
hang. Do not use local app builds, `reload-cloud`, or `maclease`. The lease
below records the completed September 16 attempt, before the fleet
allocation transition; it is not an instruction to allocate a new lease.

## Controlled fleet attempt, 2026-09-16

Result: the reported hang was **not reproduced**. No product fix was applied.

The shared lease `20260916182151-26496-27252` reserved a GUI-ready M4 Pro
(`Mac16,11`) running macOS 26.5 (`25F71`). None of the reachable hosts probed
for this attempt had the reported macOS 26.6.2. Other running apps were
left alone.

Release 0.64.23 (103) and 0.64.24 (104) were downloaded from their tagged
GitHub release assets. The 0.64.24 DMG matched the SHA-256 above, and its
original bundle passed deep/strict signature verification. Both app copies
used the unique bundle ID `com.cmuxterm.app.repro12788`, a fresh profile, and
an explicit isolated socket. Their arm64 `__text` section digests matched
the corresponding original release after signing. The app was launched
natively inside the existing Aqua session with no app arguments and no
test-mode or restore-disable environment variables. Startup logs confirmed
`xctest=0`, stable build flavor, and restored-panel commits.

| Test | Workspaces / surfaces | Fresh terminal output | Maximum measured RPC |
| --- | --- | --- | --- |
| Fresh 0.64.24 profile | 1 / 1 | Confirmed | Initial workspace query 1.36 ms |
| 0.64.23 baseline, then normal Quit | 12 / 40 | 36 of 36 terminals | 245.99 ms |
| Replace with 0.64.24, retain session, relaunch | 12 / 40 | 36 of 36 terminals | 241.02 ms |
| SIGKILL only the test process, relaunch 0.64.24 | 12 / 40 | 36 of 36 terminals | 255.81 ms |
| Persist visible Find sidebar, normal Quit/relaunch | 12 / 39 | 35 of 35 terminals | 262.30 ms |

The 40-surface fixture contained 36 local shells and four local HTML browser
panes. Each phase selected every workspace, executed a freshly generated
marker command in each terminal, read the actual output, and ran three more
workspace-selection passes. The marker was assembled by the shell from two
arguments so terminal echo alone could not satisfy the output check. All 12
workspace identities survived the version transition and both restarts.
The force-kill case retained an unclean sentinel and returned a nonempty
window list 1.214 seconds after relaunch. Computer-use text entry and Return
also produced the expected marker, visible in a captured screenshot.

The computer-use tab-button action closed one terminal in workspace 1 before
the Find-sidebar test. The `ui-input` screenshot records that 39-surface
layout **before** the next quit/relaunch; the count change is not evidence
of restore data loss. No automatic hang-capture files appeared in the test
profile. Samples and responsive RPCs do not disprove a different customer
configuration or OS-specific failure.

### Remaining differences from the customer

- macOS 26.5 / M4 Pro instead of 26.6.2 / M3 Pro.
- Isolated bundle ID and ad-hoc signature. Restricted release entitlements
  were removed for that signature; an initial attempt retaining them was
  rejected by AMFI before execution and was classified as test setup failure.
- Binary replacement and normal quit/relaunch, not Sparkle installation.
- Signed-out, telemetry-disabled profile with simple shells; no customer
  settings, managed agent sessions, remote connections, or credentials.

These are bounded negative tests, not a reproduced-and-fixed regression.
The next useful evidence is a sample from the affected process during the
hang, plus the affected session/configuration or concrete triggering steps.
The withdrawn restore-policy change must not be reintroduced on the basis
of these results.

Local artifacts are retained in the hq checkout under
`artifacts/verify-remote/20260916-issue12788-repro/`: `evidence/summary.json`,
per-phase inventories and timings, source session snapshots, original/native
code digests, startup logs, process samples, harness scripts, and computer-use
screenshots (`cold-launch`, `upgrade24`, `unclean24`, `ui-input`, `find24`).
