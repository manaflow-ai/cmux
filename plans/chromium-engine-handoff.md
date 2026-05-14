# Chromium engine — per-session handoff ledger

Read this first when starting any session on `feat-chromium-engine`. Append a new entry at the bottom of "Session log" before exiting. The "Next steps" block at the top is authoritative; update it when you finish a step.

## Next steps (always current)

- [ ] Run `./scripts/chromium-build-host.sh fetch` to begin the Chromium fetch on `cmux-aws-mac`. Pinned to Chromium M148 stable (`refs/branch-heads/7204`). Mac-only shallow checkout. Disk on host is tight (155 GB free, ~80–100 GB expected), so monitor `./scripts/chromium-build-host.sh status` during the fetch.
- [ ] After fetch completes: run `./scripts/chromium-build-host.sh build content_shell` to validate the toolchain. `content_shell` is upstream's minimal embedder; if it builds, the fork's cmux-specific target will too.
- [ ] Wire CmuxBrowserEngine into `GhosttyTabs.xcodeproj` so cmux builds against it. Today the package compiles standalone but isn't a dependency of the cmux target. Pattern: see how `Packages/CMUXAuthCore` is wired in `project.pbxproj`.
- [ ] Begin Packages/CmuxBrowserEngine expansions called out in `plans/wkwebview-surface-audit.md` "Migration order recommended": KVO/Combine mirrors → pageZoom → CmuxDataStore + CmuxCookieStore → CmuxDownload → CmuxInspector.
- [ ] Create the Chromium fork repo `manaflow-ai/cmux-chromium` (requires user permission to create org-level repo). Once created, push the M148 base commit + an empty `//cmux/embedder/` skeleton matching the C ABI in `plans/cmux-embedder-c-abi.md`.

## Active milestone

**P1 — Custom framework target.** P0 (toolchain) is done; P1 starts when the fork repo exists and the first `gn gen` succeeds with a `cmux_core_framework` target.

## Build host state

- Host: `cmux-aws-mac` (M1 Ultra, 20 cores, 128 GB RAM, macOS 15.7.4, Xcode 26.3).
- Disk situation: only 155 GB free on `/System/Volumes/Data` (the user's home). The 994 GB `disk3s4` volume mounted at `/private/tmp/tmp-mount-TOmSsz` is the **macOS firmware update volume** — held by `com.apple.MobileSoftwareUpdate.CleanupPreparePathService` and reformatted on OS updates. We do NOT use it. Renamed it to `Chromium` for clarity but the volume itself remains owned by the OS update system.
- Other AWS Mac state to note (do **not** touch): `/Users/ec2-user/chromium` (70 GB, prior unrelated project), `/Users/ec2-user/actions-runner-chromium-*` (GitHub Actions runners for that other project). Per the user's directive: ignore everything there. We use `/Users/ec2-user/chromium-fork` (fresh) for this project.
- depot_tools: installed at `/Users/ec2-user/depot_tools`, on PATH via `~/.zshrc` (managed by `./scripts/chromium-build-host.sh setup`).
- Chromium fork checkout: not started; will live at `/Users/ec2-user/chromium-fork`.

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

### Session 1 — 2026-05-14 (scaffolding)

- User confirmed scope (Dia-strategy, full Chromium fork) and approved `/loop`-paced multi-session work.
- Investigated `disk3s4`: it is the macOS firmware update volume. **Rejected** for Chromium checkout. Pivoted to `/Users/ec2-user` (155 GB free).
- Discovered an in-flight Atlas-strategy `cmux-browser` project at `worktrees/task-cmux-browser-pure-mojo/` (127 tests, working dogfood, active Chromium-side work on AWS Mac). Surfaced to user; user directed to **ignore** it and build a new project from scratch with a new Chromium fork. Atlas-project artifacts on AWS Mac (`~/chromium`, `~/actions-runner-chromium-*`) are left untouched.
- Installed `depot_tools` at `/Users/ec2-user/depot_tools`, fixed `~/.zshrc` perms.
- Built `scripts/chromium-build-host.sh` (idempotent: setup, remount, fetch, status, build).
- Built `Packages/CmuxBrowserEngine` SwiftPM package — engine-neutral API surface mirroring WKWebView. WebKit backend is production-shaped; Chromium backend is a documented stub. **16 tests passing, 0 warnings, swift 6 strict concurrency.**
- Wrote `plans/wkwebview-surface-audit.md` (every WK API cmux uses + migration order).
- Wrote `plans/cmux-embedder-c-abi.md` (C ABI sketch the cmux Chromium fork will export).
- **Did not** start the fetch (commits this session first so progress is durable; fetch is the first session-2 task).
- **Did not** create `manaflow-ai/cmux-chromium` GitHub repo (needs user OK).
- Pushed three commits to `feat-chromium-engine`, draft PR #4159 has them.

Next session: see "Next steps" above.
