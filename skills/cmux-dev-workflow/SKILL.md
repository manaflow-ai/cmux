---
name: cmux-dev-workflow
description: "Contributor workflow for native cmux setup, tagged dev builds and Xcode project normalization. Use for native build inputs, setup or tagged app verification."
---

# cmux Dev Workflow

## Scope and routing

Run repository commands only from a [trusted checkout](../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

[Choose verification for the change](../cmux-testing/references/local-vs-ci-validation.md)
before preparing a native build. Fast feedback starts with
`python3 scripts/verify-local.py`; portable-tooling and documentation changes use
their scoped checks without an unrelated app build.

For native app or build-input changes, build with a tag as below. Setup (`./scripts/setup.sh`) initializes
submodules, builds GhosttyKit and installs the project-normalization hook;
it is not a prerequisite for portable static checks.

## Tagged local development

When local native execution is authorized:

```sh
./scripts/reload.sh --tag <short-tag>
CMUX_TAG=<short-tag> scripts/cmux-debug-cli.sh workspace list
```

Reload builds without launching; add `--launch` when live verification is needed.
Never use bare `xcodebuild` or open an untagged `cmux DEV.app`: tags isolate bundle
IDs, sockets and build output from other sessions. Do not use `/tmp/cmux-cli`,
which follows the most recently reloaded app. See [tagged builds](references/tagged-builds.md).
Never quit, kill, relaunch or `xctrace --launch` the user's running cmux
(`com.cmuxterm.app`); it holds their live agent sessions.

An app build does not establish test-target compilation or execution. Follow
[the test guide](../cmux-testing/references/local-vs-ci-validation.md) for those claims.

## Toolchain and project files

`.xcode-version` owns the Xcode major. `cmux.xcodeproj/project.pbxproj` uses
objectVersion 77 because it has synchronized folders; `scripts/check-pbxproj.sh`
pins 60 for Xcode 26 and accepts 77 only with a `PBXFileSystemSynchronizedRootGroup`.
The app package needs Swift tools 6.2; see
[toolchain and macOS 14 compatibility](../cmux-architecture/references/swift-6-0-compatibility.md).

The installed pre-commit hook normalizes staged project files and registers new
Python tests in `tests/test-execution.toml`. Preserve it and
run `python3 scripts/verify-local.py --only project` after project edits. Toolchain
pin changes are deliberate team decisions; see [project normalization](references/xcode-project-normalization.md).
