# Crux Developer Setup Guide

## Platform Reality

Crux (cmux fork) is a native macOS app. The build toolchain (Xcode, Metal, AppKit) is macOS-only. It cannot compile inside a Linux container.

**Split workflow**: Vibeshield container for agent-driven code editing, review, and pure-Swift testing. macOS host for compilation and GUI testing.

## Complete Dependency Inventory

### macOS Host

| Dependency | Version | Install | Purpose |
|-----------|---------|---------|---------|
| Xcode | 15.0+ | Mac App Store | Swift compiler, AppKit, Metal, `xcodebuild` |
| Zig | 0.15.2+ | `brew install zig` | Builds GhosttyKit xcframework |
| Git | Any | Pre-installed | Submodule management |

### SPM Dependencies (resolved automatically by Xcode on first build)

| Package | Source | Version |
|---------|--------|---------|
| Sparkle | github.com/sparkle-project/Sparkle | Xcode-managed |
| sentry-cocoa | github.com/getsentry/sentry-cocoa | Xcode-managed |
| posthog-ios | github.com/PostHog/posthog-ios | Xcode-managed |
| SwiftTerm | github.com/migueldeicaza/SwiftTerm | 1.5.1 |
| swift-argument-parser | github.com/apple/swift-argument-parser | 1.7.0 |

SPM resolution requires network on first build. Xcode caches to `~/Library/Caches/org.swift.swiftpm/`.

### Git Submodules (initialized by `./scripts/setup.sh`)

| Path | Repo | Purpose |
|------|------|---------|
| `ghostty/` | manaflow-ai/ghostty | Terminal engine (Zig → xcframework) |
| `vendor/bonsplit/` | manaflow-ai/bonsplit | Split pane/tab management |
| `homebrew-cmux/` | manaflow-ai/homebrew-cmux | Homebrew tap (not needed for dev) |

### Not Needed for Development

Node.js, Apple Developer certs, Sentry token, Sparkle keys — these are release-only.

---

## Vibeshield Container Setup

Vibeshield **standard mode** allows all needed domains (`api.anthropic.com`, `github.com`, `api.github.com`).

```bash
cd ~/zed/crux
curl -fsSL https://raw.githubusercontent.com/swannysec/vibeshield/main/vibeshield -o vibeshield
chmod +x vibeshield && ./vibeshield init
cp .env.vibeshield.example .env.vibeshield
# Set ANTHROPIC_API_KEY and GITHUB_TOKEN in .env.vibeshield
./vibeshield
```

### Optional: Swift Toolchain for In-Container Unit Tests

For testing pure-Swift logic (cron parser, data model) without the macOS host:

```bash
# Inside container — requires --mode open temporarily for swift.org download
./vibeshield --mode open  # from host, before entering container

# Inside container:
curl -sL https://download.swift.org/swift-6.1-release/ubuntu2404/swift-6.1-RELEASE/swift-6.1-RELEASE-ubuntu24.04.tar.gz \
  | sudo tar xz -C /opt
sudo ln -sf /opt/swift-6.1-RELEASE-ubuntu24.04/usr/bin/swift /usr/local/bin/swift
swift --version  # → Swift version 6.1

# Then restore standard mode from host:
./vibeshield --mode standard
```

### What Works in the Container

| Task | Works? | Notes |
|------|--------|-------|
| Edit Swift files | Yes | Claude Code or editor |
| Git commit, push, create PRs | Yes | `git`, `gh` |
| Cron parser unit tests | Yes* | *Requires Swift toolchain above |
| Data model serialization tests | Yes* | *Requires Swift toolchain above |
| Scheduler engine unit tests | Yes* | *Requires Swift toolchain above |
| Code review / planning | Yes | Full agent capability |
| `xcodebuild` (any build) | **No** | Requires macOS + Xcode |
| `./scripts/reload.sh` | **No** | Launches macOS GUI app |
| GUI testing | **No** | macOS window system |
| Socket testing (`cmux ping`) | **No** | Requires running app |
| Scheduler CLI (`cmux scheduler`) | **No** | Requires running app |

---

## macOS Host Setup

### Step 1: Install Xcode

```bash
# Mac App Store or developer.apple.com/xcode
xcodebuild -version  # Verify: Xcode 15+
```

### Step 2: Install Zig

```bash
brew install zig
zig version  # Verify: 0.15.2+ (Ghostty requires minimum 0.15.2 per build.zig.zon)
```

### Step 3: Initialize Submodules & Build GhosttyKit

```bash
cd ~/zed/crux

# setup.sh handles everything: submodule init + GhosttyKit build + SHA-based caching
./scripts/setup.sh

# What it does:
# 1. git submodule update --init --recursive (ghostty, bonsplit, homebrew-cmux)
# 2. Checks for zig in PATH
# 3. Builds GhosttyKit.xcframework: cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
# 4. Caches at ~/.cache/cmux/ghosttykit/<sha>/ (instant on subsequent runs)
# 5. Symlinks GhosttyKit.xcframework at project root
```

### Step 4: Build & Launch

```bash
# Build the debug app (first build also resolves SPM packages from GitHub)
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' build

# Launch with isolated tag
./scripts/reload.sh --tag crux-dev

# Verify running:
tail -f /tmp/cmux-debug-crux-dev.log
```

---

## Dev Iteration Cycle

```bash
# After Swift edits (in container or host):
git pull  # if edited in container
./scripts/reload.sh --tag crux-dev  # rebuilds changed Swift, relaunches

# Debug log:
tail -f /tmp/cmux-debug-crux-dev.log

# GhosttyKit only needs rebuild if ghostty/ submodule is modified.
```

---

## Recommended Workflow

```
Vibeshield Container              macOS Host
  claude code                      git pull
  → edit Swift files    ──push──▶  ./scripts/reload.sh --tag crux-dev
  → unit tests                     → test GUI + socket API
  → git commit + push              → verify notifications
  → repeat                         → report results
```

---

## Verification Checklist

| Check | Command | Expected |
|-------|---------|----------|
| Xcode | `xcodebuild -version` | 15+ |
| Zig | `zig version` | 0.15.2+ |
| Submodules | `ls ghostty/build.zig` | File exists |
| GhosttyKit | `ls GhosttyKit.xcframework` | Symlink to cache |
| Build | `xcodebuild ... build` | BUILD SUCCEEDED |
| Launch | `./scripts/reload.sh --tag crux-dev` | Window opens |
| Socket | `cmux ping` | PONG |
| Scheduler | `cmux scheduler list` | Empty list or tasks |
| Vibeshield | `./vibeshield --status` | Container running |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "zig is not installed" | `brew install zig` (need 0.15.2+) |
| Zig version mismatch | `cat ghostty/build.zig.zon \| grep minimum_zig_version` then install matching |
| SPM resolution fails | `rm -rf ~/Library/Caches/org.swift.swiftpm` then rebuild |
| "already running" on reload | `pkill -x "cmux DEV" \|\| true` then retry |
| Vibeshield can't reach GitHub | `./vibeshield --mode standard` |
| Swift install needs swift.org | `./vibeshield --mode open`, install, then `--mode standard` |
