---
name: cmux-dev-workflow
description: "Contributor workflow for native cmux setup, tagged dev builds, Xcode project normalization and sidebar extensions. Use for native build inputs, setup or tagged app verification."
---

# cmux Dev Workflow

## Scope and routing

[Choose verification for the change](../cmux-testing/references/local-vs-ci-validation.md)
before preparing a native build. Fast feedback starts with
`python3 scripts/verify-local.py`; portable-tooling and documentation changes use
their scoped checks without an unrelated app build.

For native app or build-input changes, follow the current root `AGENTS.md`
build routing and capacity owner. Setup (`./scripts/setup.sh`) initializes
submodules, builds GhosttyKit and installs the project-normalization hook;
it is not a prerequisite for portable static checks.

## Tagged local development

When local native execution is authorized:

```sh
./scripts/reload.sh --tag <short-tag>
CMUX_TAG=<short-tag> scripts/cmux-debug-cli.sh list-workspaces
```

Reload builds without launching; add `--launch` when live verification is needed.
Never use bare `xcodebuild` or open an untagged `cmux DEV.app`: tags isolate bundle
IDs, sockets and build output from other sessions. Do not use `/tmp/cmux-cli`,
which follows the most recently reloaded app. See [tagged builds](references/tagged-builds.md).

An app build does not establish test-target compilation or execution. Follow
[the test guide](../cmux-testing/references/local-vs-ci-validation.md) for those claims.

## Toolchain and project files

`.xcode-version` owns the Xcode major; `cmux.xcodeproj/project.pbxproj` currently
uses objectVersion 60. The Intel/macOS 14 fallback uses Xcode 16.2/Swift 6.0;
keep app-linked code compatible as specified in root `AGENTS.md`.

The installed pre-commit hook normalizes staged project files. Preserve it and
run `python3 scripts/verify-local.py --only project` after project edits. Toolchain
pin changes are deliberate team decisions; see [project normalization](references/xcode-project-normalization.md).

## Sidebar extension tags

Keep the extension-point ID, bundle-ID suffix and display-name suffix distinct
for each tag. Build extensions through `scripts/reload-extension.sh --tag <tag>`
with the matching host; do not repair a mismatched tag by re-signing. The exact
settings, helper arguments and verification checklist live in
[sidebar extension tagging](references/sidebar-extension-tagging.md).
