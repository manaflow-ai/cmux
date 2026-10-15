# cmux-next Mac build for the cnx-ios overnight work

Run this Mac build: (pending: first build of feat-cnx-ios-macnext 9063df14 is on the fleet)

Branch `feat-cnx-ios-macnext` integrates every Mac-side fix for the cmux-next
iOS work. It is for dogfood builds only; it never merges anywhere. Each build
goes to `~/cnx-ios-builds/<date>-<sha10>-mac-prod/cmux NEXT iOS Test.app`
(bundle id `dev.cmuxterm.app.next.iostest`, the same identity as the earlier
side-by-side builds, so it replaces them). Quit the older "cmux NEXT iOS Test"
before opening a new one.

## What each merge brought

| Step | Commit | Brought in |
| --- | --- | --- |
| Base | `feat-cnx-ios-machost-d5` e1edf234 | machost lineage, supervisor restart fix 3df9ff77, round-4 daemon fixes (D4 attach wait), PR #20809 review fixes (one replay per reattach, 30 s grow-hold for dropped phones) |
| Merge | `codex-daemon-hooks-next-machost` 711ded36 | PR #20770: plain `codex` reaches notifications and the Feed (agent shim stays first on PATH, Codex daemon refuses inherited routes, hooks.state as one inline table), macOS duplicate-event fix. Clean merge. |
| Merge | `feat-cnx-ios-mactry-rbfix` c01e1c2c | everything of the earlier user build not in d5: approvals (in-app pairing sheet, identity key, pairing seed, browser-stream-v1 flag), Chief avatar (#20531), rbhost (Release builds embed and sign the remote browser host; ensure/publish scripts with the controller fallback), rbfix host pin 2765fa17 (CEF `--use-mock-keychain`). Clean merge (90 commits). |
| Merge | `feat-cnx-ios-rbfix` a1f01f2e | SECURITY.md note: the browser host never reads the login Keychain. |
| Merge | `feat-cnx-ios` 3d2a8581 | the phone side's `cnx-ios/rust` (WireGuard RTP media lane, relay path labels, roam announcements), so the bundled cnx-hostd matches the phone build. Outside `cnx-ios/` it only adds iOS-only CmuxTabsKit files. `cnx-ios/rust` now equals feat-cnx-ios except `cnx-hostd/src/chief_policy.rs`, which keeps the Chief avatar fields (`chief.engine.set {avatar}`, `chief-profile-changed`). |
| Commit | b20242a0 | a Release cmux-next app always bundles cnx-hostd built from its own source (below). |
| Merge | `feat-cnx-ios-agentcwd` e0f1c3bf (via feat-cnx-ios-parity) | the phone may start agent chats in the folders of the person's workspace tabs: acpmux `_acpmux/workspace_roots_set`, the Mac sends its tab folders on the person connection while iPhone connections are on. SECURITY.md conflict resolved by keeping both sections. Trust-policy item for #13742; the user approved it for dogfood (2026-10-14 night). Parity commit 7582c2aa (drop a duplicate test) is not needed here: this tree has one copy of that test. |

Not merged: PRs #20757, #20770 and #20809 stay open against their bases.

## cnx-hostd is always in a Release app

Before: the "Bundle cnx-hostd" phase skipped a Release build silently when
`CMUX_NEXT_CNX_HOSTD_BIN` was unset, and Linux-pool fleet builds shipped no
cnx-hostd (fleet side fixed in cmuxterm-hq #2091). Now (b20242a0):

- `scripts/cmux-next/bundle-cnx-hostd.sh` fails a Release build that has no
  cnx-hostd, or whose `.ref` names another source key than this checkout
  (`build-cnx-hostd.sh --print-key`). `CMUX_NEXT_CNX_HOSTD_OPTIONAL=1` is the one
  explicit opt-out (set only on the dev-daily Release compile, which never built it).
- `scripts/reload.sh` stops a Release build before the compile when no cnx-hostd
  can be built on that machine.
- `release.yml` builds cnx-hostd for the app bundle, as nightly-next does.
- Test: `scripts/cmux-next/tests/bundle-cnx-hostd-release.test.sh` (in cmux-next.yml).

## Builds

| When (UTC) | SHA | Fleet job | Path | Result |
| --- | --- | --- | --- | --- |
| 2026-10-15 | 9063df14 | prod cbd41d5d, rig 79c6e58c | pending | pending |
