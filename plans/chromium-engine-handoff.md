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

#### Strategic note for session 3

The `patches/` directory grew from 1 entry (session 1's metal-toolchain xcrun-resolve) to 4 entries during session 2:

  - 0001 metal-wrapper xcrun-resolve (ANGLE)
  - 0002 webnn CoreML `MLMultiArrayDataType` default-branch
  - 0003 ax inspect availability suppression (function-scoped)
  - 0004 ax_platform_node_cocoa availability suppression (file-scoped)

Patches 0002-0004 are all macOS-26-SDK forward-compat issues. The current checkout is at Chromium **main HEAD** (commit `72a51d14d794ce9211145ecc9b7464e222d40153`, a ChromeOS LKGM from 2026-04-16) — NOT at M148 stable (`refs/branch-heads/7204`) the build host script declares as its target branch.

Hypothesis for session 3: **before chasing more SDK forward-compat patches, switch the checkout to `refs/branch-heads/7204` and re-run `gclient sync`.** M148 stable was tested against earlier SDKs and likely compiles cleanly under macOS 26.2 with only patch 0001 (the cryptex Metal-toolchain issue is OS-level, not chromium-version-specific). Cost: one git checkout + gclient sync (hours, but cached). Benefit: fewer patches to maintain across upstream rebases.

If session 3 takes that path: `patches/0002`–`patches/0004` may be removable. Validate by attempting the build without them after the branch switch.

### Session 3 — 2026-05-14 (M148 reality check + stubs + gn-format)

Continued under the same `/goal i have reviewed it, use your best judgment and implement fully` stop-hook from sessions 1 and 2.

- **Session 2 strategic recommendation was wrong, retracted.** `git ls-remote origin refs/branch-heads/7204` on the cmux-aws-mac chromium-fork checkout resolves to `72a51d14d794ce9211145ecc9b7464e222d40153` — the exact commit the checkout was already on. The LKGM-shaped HEAD commit message ("Automated Commit: LKGM 16295.95.0 for chromeos.") obscured that fact. **M148 stable IS the current base; there is no cheaper branch to switch to.** `patches/README.md` retracts the misleading note.
- **Patch 5 (rename, not suppress).** Build round 6 failed at `ui/accessibility/platform/browser_accessibility_cocoa.mm:2192` and friends with `error: reference to 'NSAccessibilityUIElementsForSearchPredicateParameterizedAttribute' is ambiguous` — the same identifier was declared in an anonymous namespace as a private backport AND in the macOS 26.2 SDK as `@available(macos 26.0)`. Unlike patches 0003/0004 (`-Wunguarded-availability-new`), this is a hard collision error a diagnostic pragma cannot silence. `patches/0005-ax-cocoa-rename-private-symbol-backports.patch` renames the anonymous-namespace `NSAccessibilityUIElementsForSearchPredicateParameterizedAttribute` and `NSAccessibilityScrollToVisibleAction` to `CmuxNS*` prefixed identifiers; string-literal values unchanged, deployment-target behavior unchanged.
- **BUILD.gn rewrites against real upstream patterns.** Session 2's `embedder/cmux_BUILD.gn` had three independent bugs: out-of-bounds `helper[3]`/`[4]`/`[5]` (the `content_mac_helpers` tuple is exactly 3-wide), target-name drift between the `foreach` and the `group("cmux_helpers")` deps list, and an over-coupled inline body where the upstream pattern factors a template. Rewrote against `chrome/BUILD.gn:730` (`chrome_helper_app` template body) and `chrome/BUILD.gn:826` (foreach iteration). Group target list is now generated FROM `content_mac_helpers` so names cannot drift.
- **Stub .cc/.mm files matching every C ABI function.** Added `embedder/cmux_session.cc`, `cmux_profile.cc`, `cmux_view.cc`, `cmux_browser.mm`, `cmux_layer_host.mm` (empty placeholder), `cmux_helper_main_mac.cc`, and `cmux_framework_main.cc`. Session 2 had argued these "would rot" if written speculatively; the session-3 stubs only do trivial sentinels (return `CMUX_E_NATIVE` / NULL / 0 / "") and use a shared `cmux_internal_set_last_error` helper, so there is no implementation surface to rot. The framework can link without any //content wiring. Re-enabled the .mm/.cc paths in `embedder/BUILD.gn`'s source list (session 2 had commented them out because the files didn't exist).
- **`gn format` validates both BUILD.gn files.** Copied `cmux_BUILD.gn` → `~/chromium-fork/src/cmux/BUILD.gn` and `BUILD.gn` → `~/chromium-fork/src/cmux/embedder/BUILD.gn` on cmux-aws-mac. Round-tripped both through `gn format` (from depot_tools); only diffs were GN's single-line collapses for length-1 lists. Pulled the gn-blessed versions back to the worktree as canonical. This validates GN syntax but NOT semantics (target lookups, source-file existence beyond this directory, template arg type checks) — those require the framework to be reachable from a default `gn_all` target, which it is not yet.
- **Build round 7 in flight.** With patches 0001–0005 applied, kicked off `autoninja -C out/cmux_release -k 0 content_shell` again on cmux-aws-mac (pid 99363). At session-3 close: 1820/15871 (~11.5%) at 9m55s elapsed, past prior failure point. ScheduleWakeup set for 30 min to react to outcome.
- Pushed four commits to `feat-chromium-engine`: `136435be` patch 5 + retract M148 note, `75b96402` BUILD.gn rewrites, `cb8a5caa` stub .cc/.mm files, `086fe1f1` gn-format outputs.

#### What session 3 added to "proved"

- M148 stable IS the current chromium-fork base. The session-2 hypothesis that switching branches would reduce SDK forward-compat patches is **falsified**: the LKGM tip and `refs/branch-heads/7204` are literally the same commit.
- Both embedder BUILD.gn files round-trip cleanly through `gn format` against M148. Syntax is GN-correct.
- Every function exported by `cmux_browser.h` has a stub body in `embedder/*.{cc,mm}`. The framework has every symbol the linker will look for.
- `embedder/cmux_BUILD.gn`'s helper-app instantiation pattern matches `chrome/BUILD.gn:826` line-for-line semantically.

#### What session 3 did NOT prove

- `content_shell` itself building green end-to-end. Round 7 was in flight at session-3 close. **If another forward-compat error fires**, follow patch discipline: capture as a numbered patch (this run brought the total to 5), wire into `apply-patches`, restart.
- The embedder BUILD.gn files compile in a real Chromium build graph. `gn format` is a syntactic check; `gn check` requires the framework to be reachable, which still depends on either (a) creating `manaflow-ai/cmux-chromium` and integrating `//cmux:cmux_core_framework` into `gn_all`, or (b) hand-modifying BUILDCONFIG.gn for a one-off check (deliberately not done — would dirty the chromium-fork tree).
- The C ABI stubs link against `//content`'s `BrowserMainRunner` — they don't. They are pure-sentinel implementations of the ABI surface, suitable for proving the linker has every symbol, not for proving anything renders.

#### Strategic note for session 4

The patch arc 0001 → 0005 covers four distinct fix classes on macOS 26.2 SDK + M148 stable:

  - **0001** (metal-wrapper): macOS-level toolchain layout. Will recur on every macOS-26-class SDK; consider upstream contribution.
  - **0002** (webnn CoreML enum): macOS 26.2 SDK adds enum values. Forward-compat default branch; harmless.
  - **0003 / 0004** (availability suppression): macOS 26 SDK marks pre-existing constants as `@available(macos 26.0)`. Suppression unblocks build.
  - **0005** (rename SDK-shadow): macOS 26 SDK publishes identifiers Chromium had been backporting in anonymous namespace. Rename is more invasive than the others but the only fix shape that survives a hard name-collision error.

Each pattern is now demonstrated; subsequent SDK forward-compat errors should match one of these four shapes. A new fix class (linker, mojom regeneration, ABI break) is the signal to call the advisor before continuing.

Session 4 should open by checking `~/chromium-fork/build-content-shell.log`'s tail. If `Content Shell.app` exists at `~/chromium-fork/src/out/cmux_release/Content\ Shell.app`, build round 7 succeeded and P0 is decisively done; otherwise diagnose the next failure under the four-pattern taxonomy above.

P1 still requires user permission to create `manaflow-ai/cmux-chromium` org-level repo. Until that exists, the `embedder/` tree cannot move into a real `gn gen` graph and the framework cannot be evaluated end-to-end.
