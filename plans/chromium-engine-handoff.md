# Chromium engine — per-session handoff ledger

Read this first when starting any session on `feat-chromium-engine`. Append a new entry at the bottom of "Session log" before exiting. The "Next steps" block at the top is authoritative; update it when you finish a step.

## Next steps (always current)

- [x] Confirm the `:base` smoke build finished green on `cmux-aws-mac`. ✅ 2026-05-14 session 1: `1m33.11s Build Succeeded: 2192 steps - 23.54/s`.
- [ ] Verify the `content_shell` build (started session 2 with metal patch). Build log at `~/chromium-fork/build-content-shell.log`. Round 3 of the build is in flight as of session 2 close. Once it lands green, the wider Chromium target graph is proven.
- [ ] Wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` so cmux's main target picks it up. Today the package compiles standalone (32 tests green) but isn't a dependency. Pattern: see how `Packages/CMUXAuthCore` is referenced in `project.pbxproj`.
- [ ] Migrate audit step 5: `CmuxInspector` (the only remaining migration-order item — explicitly last because the inspector is its own subsystem).
- [ ] Create the Chromium fork repo `manaflow-ai/cmux-chromium` (requires user permission to create org-level repo). Once created, push the M148 base commit + an empty `//cmux/embedder/` skeleton matching the C ABI in `plans/cmux-embedder-c-abi.md`. Patches in `patches/` get squashed in at that point.
- [ ] Once the fork repo exists, push `//cmux/embedder/cmux_browser.h` (from `plans/cmux-embedder-c-abi.md`) and the matching `BUILD.gn` for a `cmux_core_framework` target. First real build with that target = end of P1.

## Active milestone

**P1 — Custom framework target.** P0 (toolchain, fetch, gn gen) done. P1 starts when the fork repo exists and `cmux_core_framework` builds.

## Build host state

- Host: `cmux-aws-mac` (M1 Ultra, 20 cores, 128 GB RAM, macOS 15.7.4, Xcode 26.3).
- Disk: 128 GB free on `/System/Volumes/Data` (was 155 GB before the fetch; the checkout is 26 GB). Comfortable margin remains for a content_shell build (~10 GB build output) and a cmux_core_framework build (~15 GB). Tight for `chrome` itself.
- The 994 GB `disk3s4` volume is the **macOS firmware update volume** — held by `com.apple.MobileSoftwareUpdate.CleanupPreparePathService` and reformatted on OS updates. Renamed it `Chromium` for clarity, do not put a checkout on it.
- Other AWS Mac state to ignore (per user directive): `/Users/ec2-user/chromium` (70 GB, prior unrelated project), `/Users/ec2-user/actions-runner-chromium-*` (GitHub Actions runners for that other project). Our fork lives at `/Users/ec2-user/chromium-fork`.
- depot_tools: installed at `/Users/ec2-user/depot_tools`, on PATH via `~/.zshrc`.
- Chromium fork checkout: **fetched** at `/Users/ec2-user/chromium-fork`. Tracks Chromium main HEAD as of 2026-05-14, will be re-pointed to `refs/branch-heads/7204` (M148 stable) once the fork repo exists. `gn gen out/cmux_release` succeeds (27,361 targets from 4,064 .gn files).

## Open blockers

- Need user OK to create `manaflow-ai/cmux-chromium` GitHub repo (org-level repo creation).

## Open PRs

- https://github.com/manaflow-ai/cmux/pull/4159 (draft) — `feat-chromium-engine` → `main`. Contains the plan docs, CmuxBrowserEngine package, build-host script, audit, C ABI design. Should not be merged yet; it's the durable home for the spike's planning + scaffolding.

## Useful commands

```bash
# Re-enter worktree
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-chromium-engine

# Build host operations (idempotent)
./scripts/chromium-build-host.sh status
./scripts/chromium-build-host.sh setup
./scripts/chromium-build-host.sh fetch
./scripts/chromium-build-host.sh build cmux_core_framework

# CmuxBrowserEngine package
cd Packages/CmuxBrowserEngine && swift test

# Read the ledger
cat plans/chromium-engine-handoff.md
```

## Useful files

- `plans/chromium-engine.md` — master plan: architecture, milestones, risk register.
- `plans/wkwebview-surface-audit.md` — every WK API cmux touches; migration order.
- `plans/cmux-embedder-c-abi.md` — C ABI design for the Chromium fork's `//cmux/embedder/`.
- `Packages/CmuxBrowserEngine/` — engine-neutral Swift wrapper (compiles today on WebKit).
- `scripts/chromium-build-host.sh` — bootstrap + run commands for `cmux-aws-mac`.

## Session log

### Session 0 — 2026-05-14 (planning)

- Verified `cmux-aws-mac` reachable (M1 Ultra, 128 GB, Xcode 26.3).
- Identified persistent storage candidate `disk3s4`.
- Created worktree `feat-chromium-engine` off `origin/main` at `791318f5a`.
- Drafted `plans/chromium-engine.md` (architecture, milestones, cost, risk register).
- Drafted this handoff ledger.
- **Did not** install depot_tools, **did not** fetch Chromium. Decision: wait for user to confirm scope.
- Opened draft PR #4159.

### Session 1 — 2026-05-14 (scaffolding + fetch)

User set `/goal i have reviewed it, use your best judgment and implement fully` after reviewing PR #4159. Stop-hook stayed armed throughout the session.

- User confirmed scope (Dia-strategy, full Chromium fork) and approved `/loop`-paced multi-session work.
- Investigated `disk3s4`: it is the macOS firmware update volume. **Rejected** for Chromium checkout. Pivoted to `/Users/ec2-user` (155 GB free at start, 128 GB after fetch).
- Discovered an in-flight Atlas-strategy `cmux-browser` project at `worktrees/task-cmux-browser-pure-mojo/` (127 tests, working dogfood, active Chromium-side work on AWS Mac). Surfaced to user; user directed to **ignore** it and build a new project from scratch with a new Chromium fork. Atlas-project artifacts on AWS Mac (`~/chromium`, `~/actions-runner-chromium-*`) are left untouched.
- Installed `depot_tools` at `/Users/ec2-user/depot_tools`, fixed `~/.zshrc` perms.
- Built `scripts/chromium-build-host.sh` (idempotent: setup, remount, fetch, status, build).
- Built `Packages/CmuxBrowserEngine` SwiftPM package — engine-neutral API surface mirroring WKWebView. WebKit backend is production-shaped; Chromium backend is a documented stub. Wrapper covers: configuration, navigation delegate, UI delegate, user content controller, script message handler, URL scheme handler, state mirrors (Combine), pageZoom. **19 tests passing, 0 warnings, swift 6 strict concurrency.**
- Wrote `plans/wkwebview-surface-audit.md` (every WK API cmux uses + migration order).
- Wrote `plans/cmux-embedder-c-abi.md` (C ABI sketch the cmux Chromium fork will export).
- Kicked off `gclient sync` on `cmux-aws-mac`. First attempt died because macOS `nohup` doesn't support ssh-exec heredoc (no real tty). Fixed the script to use the subshell-then-background pattern, restarted. **Fetch completed: 26 GB, all runhooks ran, exit clean.**
- Ran `gn gen out/cmux_release`: success, 27,361 targets parsed from 4,064 .gn files.
- Kicked off `:base` smoke build via `autoninja` in a detached subshell. **Result: `1m33.11s Build Succeeded: 2192 steps - 23.54/s`.** Toolchain validated: Xcode CLT, sysroot, siso, ANGLE shaders, base/ all compile. Artifact `out/cmux_release/obj/base/...` confirmed.
- **Did not** create `manaflow-ai/cmux-chromium` GitHub repo (needs user OK).
- **Did not** wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` (pbxproj edits are touchy; deferred).
- **Did not** implement the Chromium backend. `ChromiumBrowserBackend` is still the documented stub.
- **Did not** take screenshots of Chromium-in-cmux (cannot — backend unimplemented, package unwired).
- Pushed six commits to `feat-chromium-engine`; draft PR #4159 has them.

### What session 1 proved vs did not prove

Proved:
- Engine-neutral Swift wrapper compiles and tests pass against WebKit backend (19/19, 0 warnings, swift 6 strict).
- Chromium toolchain on `cmux-aws-mac` is sound: fetch (26 GB) → `gn gen` (27,361 targets) → `autoninja :base` (clean build) all green.
- The architectural seam (CmuxBrowserEngine package + backend protocol + Chromium stub) is shaped so a Chromium backend can drop in without touching cmux call sites.

Did NOT prove:
- The Chromium backend works. It's a `fatalError` stub.
- CmuxBrowserEngine is reachable from cmux. `GhosttyTabs.xcodeproj` does not depend on the package yet.
- Anything renders inside cmux from Chromium. No screenshots possible until P1-P3 land.
- The fork repo exists. `manaflow-ai/cmux-chromium` is not created; the embedder C ABI is design-only.

Next session: see "Next steps" above. Start with `content_shell` build to validate the wider Chromium target graph before the fork-specific `cmux_core_framework` target.

### Session 2 — 2026-05-14 (content_shell + package expansions)

Continued under the same `/goal i have reviewed it, use your best judgment and implement fully` stop-hook from session 1.

- Kicked off `content_shell` build. Round 1 died at `//third_party/angle/.../metal:angle_metal_internal_shaders_to_air` with `error: cannot execute tool 'metal' due to missing Metal Toolchain`. Root cause: macOS 15 + Xcode 26 ships the Metal compiler toolchain as a separate downloadable component mounted under `/var/run/com.apple.security.cryptexd/.../Metal.xctoolchain/usr/bin/`; the Xcode stub at `XcodeDefault.xctoolchain/usr/bin/metal{,lib}` does NOT auto-locate that mount. `xcrun --find <tool>` does. Worse, `metallib` doesn't even exist as a stub.
- Wrote `patches/0001-angle-metal-wrapper-resolve-via-xcrun.patch` and applied it to the host's checkout: ANGLE's `metal_wrapper.py` now detects the broken Xcode metal-family stub paths and xcrun-resolves the real binary. Round 2 still hit the same wrapper for `metallib`; round 3 covers both. After the third restart, `.air` (149 KB) and `.metallib` (359 KB) produce cleanly and content_shell is compiling through the wider target graph.
- Added `apply-patches` subcommand to `scripts/chromium-build-host.sh` so a fresh build host can be one-shot-patched.
- Continued audit migration order in `Packages/CmuxBrowserEngine`:
  - **CmuxDataStore** (step 3) — wraps `WKWebsiteDataStore` with `.default()`, `.nonPersistent()`, `.forIdentifier(UUID)`. Lazy `cookieStore` accessor. `allDataTypes()` static. `removeData(ofTypes:modifiedSince:)` async.
  - **CmuxCookieStore** (step 3) — wraps `WKHTTPCookieStore` with `allCookies/setCookie/deleteCookie/addObserver/removeObserver`. Private WK observer shim dispatches `cookiesDidChange(in:)`.
  - `CmuxBrowserConfiguration.dataStore` plumbed into `WKWebViewConfiguration.websiteDataStore`.
  - **CmuxDownload** + **CmuxDownloadDelegate** (step 4) — engine-neutral wrapper around `WKDownload`/`WKDownloadDelegate`. Strong-references shims per-WKDownload and clears them in terminal callbacks. `CmuxNavigationDelegate` gains `didBecome download` extensions; backend's nav bridge invokes them.
  - **CmuxSnapshotConfiguration** (step 6) — bridges `WKSnapshotConfiguration` (rect, snapshotWidth, afterScreenUpdates). `CmuxBrowserView.takeSnapshot(configuration:completionHandler:)` overload added.
- **Tests:** 32 total (was 19), all green, 0 warnings, swift 6 strict concurrency.
- Round 4 of content_shell hit `services/webnn/coreml/utils_coreml.mm`: macOS 26.2 SDK introduced new `MLMultiArrayDataType` enumerators that upstream chromium HEAD hasn't enumerated. `-Werror,-Wswitch` broke. Wrote `patches/0002-webnn-coreml-handle-new-mlmultiarraydatatype.patch` (adds a default branch returning 0; webnn isn't on cmux's critical path). Wired into `apply-patches`. Restarted round 4 with both patches applied; build progressing through V8 base when monitors were killed for high event volume.
- Staged drop-in-ready artifacts for the future fork repo under `embedder/`:
  - `embedder/cmux_browser.h` — full v1 C ABI as a real header (not just a sketch in markdown).
  - `embedder/BUILD.gn` — `//cmux/embedder:embedder` + `:embedder_headers` source sets.
  - `embedder/cmux_BUILD.gn` — `//cmux:cmux_core_framework` mac_framework_bundle plus the four helpers (renderer/gpu/plugin/main) re-instantiated with cmux bundle IDs.
  - `embedder/branding/cmux_core_framework-Info.plist` — Info.plist for `CmuxCore.framework`. Substitutions match `cmux_BUILD.gn`.
  - `embedder/branding/cmux_helper-Info.plist` — Info.plist for the four helpers; mirrors upstream `chrome/app/helper-Info.plist`.
  - `embedder/CHANGELOG.md` — ABI v1 surface frozen; what's intentionally out of v1 listed.
  - `embedder/README.md` — index + the mapping from this directory to the fork's `src/cmux/`.
- Updated `plans/chromium-engine.md`: P0 marked DONE, P1 marked in-progress and gated on fork repo creation, P2 Swift surface marked DONE with C-side gated on fork repo.
- Updated `plans/wkwebview-surface-audit.md`: migration order steps 1-4 + 6 marked ✅ shipped; only step 5 (CmuxInspector) remains and is explicitly deferred-last.
- **Did not** wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` (deferred again — pbxproj edits warrant their own session).
- **Did not** implement `CmuxInspector` (step 5 in the audit is explicitly last).
- **Did not** create `manaflow-ai/cmux-chromium` (still needs user OK).
- **Did not** implement the .mm/.cc impl files (cmux_browser.mm, cmux_view.cc, cmux_session.cc, cmux_profile.cc, cmux_layer_host.mm) — those go straight into the fork rather than staging here; they need content/ as a build-resolvable dep.
- Pushed 16 commits to `feat-chromium-engine`; draft PR #4159 has them all.

#### What session 2 added to "proved"

- ANGLE Metal shader compilation works on this host class (patched wrapper verified by successful `:angle_metal_internal_shaders_to_*` steps producing 149 KB `.air` + 359 KB `.metallib`).
- webnn CoreML compile is unstuck on macOS 26.2 SDK (utils_coreml.o builds at 131 KB after patch #2).
- Engine-neutral wrappers exist for: data store, cookie store, downloads, snapshot config (in addition to nav, UI, scripts, scheme handlers, state mirror, pageZoom).
- The fork's `patches/` directory is the durable home for chromium-side patches; `scripts/chromium-build-host.sh apply-patches` is idempotent and exercised twice (against both patches).
- `embedder/` directory holds the complete set of drop-in-ready files for the moment the fork repo exists: C ABI header, both BUILD.gn files (source set + framework), both branding plists (framework + helpers), CHANGELOG, README. The fork's first P1 build only needs the .mm/.cc impl files written.

#### What session 2 did NOT prove

- `content_shell` itself building green end-to-end. Round 4 was in flight at session-2 close (last seen ~1252/20438 steps, no failures). Verify next session via `tail ~/chromium-fork/build-content-shell.log` and `ls ~/chromium-fork/src/out/cmux_release/Content\ Shell.app/Contents/MacOS/`. **If another forward-compat error fires**, follow the same patch-discipline: capture as a numbered patch under `patches/`, wire into `apply-patches`, restart.
- CmuxBrowserEngine is still **not** linked into `GhosttyTabs.xcodeproj`. The package compiles in isolation but cmux's main target still uses raw WKWebView.
- The Chromium backend is still a `fatalError` stub. No screenshots of "Chromium-in-cmux" possible until P1's impl files land in the fork.
