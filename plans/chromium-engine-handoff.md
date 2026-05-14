# Chromium engine — per-session handoff ledger

Read this first when starting any session on `feat-chromium-engine`. Append a new entry at the bottom of "Session log" before exiting. The "Next steps" block at the top is authoritative; update it when you finish a step.

## Next steps (always current)

- [ ] Confirm the `:base` smoke build finished green on `cmux-aws-mac` (started 2026-05-14 session 1). Check `cat ~/chromium-fork/build-base.log` and that `ninja: build stopped` is absent. If failed, debug toolchain (Xcode CLT path, sysroot) before proceeding.
- [ ] Build `content_shell` next: `./scripts/chromium-build-host.sh build content_shell`. Roughly 30-60 min on M1 Ultra at -j16. This is upstream's minimal embedder; if it builds, the fork's `cmux_core_framework` target will too.
- [ ] Wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` so cmux's main target picks it up. Today the package compiles standalone but isn't a dependency. Pattern: see how `Packages/CMUXAuthCore` is referenced in `project.pbxproj`.
- [ ] Continue Packages/CmuxBrowserEngine expansions from `plans/wkwebview-surface-audit.md` "Migration order recommended". DONE so far: KVO/Combine mirrors, pageZoom. NEXT: CmuxDataStore + CmuxCookieStore (wraps `WKWebsiteDataStore(forIdentifier:)` and `httpCookieStore` — see `Sources/Panels/BrowserPanel.swift:383-3010` for the cmux-specific profile/data-store dance that needs neutralizing).
- [ ] Create the Chromium fork repo `manaflow-ai/cmux-chromium` (requires user permission to create org-level repo). Once created, push the M148 base commit + an empty `//cmux/embedder/` skeleton matching the C ABI in `plans/cmux-embedder-c-abi.md`.
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
- Kicked off `:base` smoke build via `autoninja` in a detached subshell; monitor armed. (Outcome captured in `~/chromium-fork/build-base.log`; check on session-2 entry.)
- **Did not** create `manaflow-ai/cmux-chromium` GitHub repo (needs user OK).
- **Did not** wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` (pbxproj edits are touchy; deferred).
- Pushed five commits to `feat-chromium-engine`; draft PR #4159 has them.

Next session: see "Next steps" above. Start by verifying the `:base` build finished green.
