# Hardcoded Path Audit

Audit date: 2026-03-22

This document records the current repo-wide classification of hardcoded path
mentions after the Stage 3 path-repair pass.

The goal is to separate:

- intentional stable literals
- stale path assumptions that should be repaired
- code paths that need explicit justification before future cleanup work touches
  them

## Decision Rules

Treat these as intentional by default:

- the stable project filename `GhosttyTabs.xcodeproj`
- the settled filesystem path `Apps/cmux-macOS/GhosttyTabs.xcodeproj`
- workflow-local checkout paths created inside a workflow, such as
  `path: homebrew-cmux`
- runtime and test socket/tmp paths under `/tmp/cmux*` when they are part of
  the supported debug, UI-test, or automation contract
- Xcode-owned internals such as scheme container names and project-file
  entitlements entries

Treat these as suspicious by default:

- repo-root `GhosttyTabs.xcodeproj` usage outside Xcode-owned internals
- repo-root `ghostty` or `homebrew-cmux` usage when referring to this repo's
  on-disk layout
- VM examples that still use `/Users/cmux/GhosttyTabs`
- shell examples that still `cd ghostty` or `git add ghostty` from the parent
  repo

## Intentional / Stable Literals

### Workflows and scripts

- Workflow `hashFiles(...)` expressions that use
  `Apps/cmux-macOS/GhosttyTabs.xcodeproj/...` are correct and must stay literal
  because Actions expressions cannot source `cmux-paths.sh`.
- `daemon/remote` in workflows is correct and matches the settled layout.
- `path: homebrew-cmux` in `update-homebrew.yml` is intentional because the
  workflow checks out an external repository into that temporary directory.
- `scripts/lib/cmux-paths.sh` is the source of truth for shell-side path
  resolution, including `CMUX_XCODE_PROJECT_PATH`,
  `CMUX_APP_ENTITLEMENTS_PATH`, `CMUX_GHOSTTY_DIR`, and
  `CMUX_HOMEBREW_TAP_DIR`.

### App and project internals

- `Apps/cmux-macOS/Sources/Workspace.swift` uses
  `Apps/cmux-macOS/GhosttyTabs.xcodeproj/project.pbxproj` as a repo-root
  marker. This is intentional and matches the settled layout.
- `Apps/cmux-macOS/GhosttyTabs.xcodeproj/project.pbxproj` references
  `cmux.entitlements` and `Resources/cmux.entitlements`. Those are Xcode-owned
  project internals and should not be treated as stale literals.
- Xcode scheme files that reference `container:GhosttyTabs.xcodeproj` are
  intentional and should not be renamed just because the project moved.

### Runtime and test contracts

- `/tmp/cmux-debug.sock`, `/tmp/cmux-debug-<tag>.sock`, `/tmp/cmux-last-*`,
  and related `/tmp/cmux-*` sockets, manifests, logs, and screenshots are part
  of the current automation and diagnostics contract.
- `/Applications/cmux.app/Contents/Resources/bin/cmux` remains a valid stable
  installed-app path and should not be treated as a reorg bug by default.

## Stale / Needs Repair

### Hidden helper docs

The earlier stale helper-doc path cluster under `.claude/commands/` has been
repaired.

Those files now use the settled layout:

- `Apps/cmux-macOS/GhosttyTabs.xcodeproj/project.pbxproj`
- `vendor/ghostty`
- `vendor/homebrew-cmux`

### User-facing docs and skills

The earlier stale path cluster in `CLAUDE.md`, `docs/ghostty-fork.md`,
`docs/agent-browser-port-spec.md`, `docs/v2-api-migration.md`, and
`skills/cmux-debug-windows/SKILL.md` has been repaired.

This audit document still mentions the old examples as historical findings, but
the live docs and skills surfaces above now reflect the settled layout.

Current settled examples:

- compile-only build examples now use
  `Apps/cmux-macOS/GhosttyTabs.xcodeproj`
- Ghostty submodule workflow docs now use `vendor/ghostty`
- VM test runner examples now use `/Users/cmux/cmux`

### CLI fallback logic

The earlier stale helper fallback in `Apps/cmux-macOS/CLI/cmux.swift` has been
repaired so the repo-level helper lookup now targets `vendor/ghostty`.

## Audit And Justify

These should stay in future searches, but they are not immediate cleanup
targets:

- `Apps/cmux-macOS/CLI/cmux.swift:7271`, `:7610`, `:10903`, `:11032`

These usages rely on the stable project filename as an ancestor marker and then
search for app-local resources or metadata. They should only be changed if the
follow-up code review proves the resolved sibling paths are wrong for the moved
layout.

Current judgment:

- `projectFile` lookup for version extraction is justified
- `repoInfo` lookup for `Resources/Info.plist` is justified when the ancestor is
  `Apps/cmux-macOS`
- `repoResources` and `repoThemes` app-local resource lookups are likely still
  justified when the ancestor is `Apps/cmux-macOS`
- `repoHelper` lookup now follows the settled `vendor/ghostty/zig-out/bin`
  path contract

## Recommended Follow-Up Pass

A future cleanup pass should:

1. Verify the repaired hidden helper docs remain aligned with the settled layout.
2. Verify the repaired user-facing docs and skill instructions listed above
   remain aligned with the settled layout.
3. Re-run the same search patterns and keep this document in sync so intentional
   literals remain documented rather than rediscovered.
