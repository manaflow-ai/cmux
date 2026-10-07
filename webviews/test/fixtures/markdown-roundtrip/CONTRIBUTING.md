# Contributing to cmux

New here? Read [docs/start-here.md](docs/start-here.md) first: how to pick an
issue, what you can fix without a Mac, and what happens to your pull request.
This file is the mechanics: setup, checks, CI and the pull request checklist.

Be nice, assume the best: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Write issues
and pull requests the way the short [writing guide](STYLE.md) says.

## Prerequisites

Only needed for the native app. Docs, translations, Python tooling, `cmux-tui` and
`web/` work on Linux; see [what you can fix without a Mac build](docs/start-here.md#2-things-you-can-fix-without-a-mac-build).

- macOS 26 (the app's deployment target)
- Xcode 26 (the pinned toolchain)
- [Zig](https://ziglang.org/) (install via `brew install zig`)
- [Rust](https://rustup.rs): `scripts/setup.sh` requires `rustup`. The official installer puts
  `rustup` and `cargo` in `~/.cargo/bin`, which is where `setup.sh` looks:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- [Zig](https://ziglang.org/): `brew install zig`
- [Rust](https://rustup.rs). Every app build compiles the bundled `cmux-cua` engine
  with `cargo`, and `scripts/setup.sh` looks for `rustup` in `~/.cargo/bin`, where
  the official installer puts it:

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

  Homebrew's `rustup` works too, but it is keg-only: add `$(brew --prefix rustup)/bin`
  to `PATH` and run `rustup default stable` yourself.

## Getting Started

```bash
git clone --recursive https://github.com/manaflow-ai/cmux.git
cd cmux
./scripts/setup.sh
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag my-feature
```

- `setup.sh` initializes the submodules, installs the pinned Rust toolchain, and
  fetches a checksum-pinned prebuilt `GhosttyKit.xcframework` (it builds from source
  with Zig if that fails; force that with `CMUX_GHOSTTYKIT_NO_PREBUILT=1`).
- `reload.sh --tag <tag>` builds a tagged Debug app and prints its path. Add
  `--launch` to open it, or `--build-only` to only compile.
  `CMUX_DEV_BACKEND_MODE=local` points it at the local dev origin; without it a
  tagged build expects the maintainers' shared backend and stops. See
  [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md) for cache
  reuse and Release variants.
- After pulling changes to setup or the merge drivers, rerun
  `./scripts/install-git-hooks.sh`. With a custom `core.hooksPath` it prints the
  `pre-commit` and `post-merge` lines to add yourself; wire both.

Team members with a Stack account can also sign DEBUG builds in and attach an iOS
build: see [team dev setup](docs/team-dev-setup.md).

<a id="fast-checks-before-building-or-pushing"></a>

## Fast checks before committing or building

Run `python3 scripts/verify-local.py` on your reviewed checkout. It selects
affected static checks and parses changed Swift, including committed branch edits.
The base comes from local `upstream/HEAD`, then `origin/HEAD`; nothing is fetched.
Use `--list` to preview, `--all` for the full CI static recipe, or `--affected BASE`
to choose a different static comparison base.

Checks cover localization, project wiring, package grouping, generated policy
and feature flags. Unknown inputs or a missing base select the full static recipe.
CI also keeps the full static recipe. Failures print a focused rerun command:

```sh
python3 scripts/verify-local.py --only project
```

It picks the static checks your diff touches (localization, project and test
wiring, package grouping, generated policy, feature flags) and parses changed
Swift. It compares against your local `upstream/HEAD`, then `origin/HEAD`, and
fetches nothing. When a check fails it prints the rerun command, for example:

```bash
python3 scripts/verify-local.py --only project --only test-wiring
```

`--list` previews, `--all` runs the full static recipe CI uses, and `--receipt -`
prints JSON ([details](docs/verification-receipts.md)). Parsing is not typechecking
or testing. The script runs repository code, so use a
[trusted checkout](docs/contributor-verification.md#trust-boundary). Git push does
not run it for you.

For `web/` and other JS/TS sources, run `bun run biome:check` from the repository
root. The root `biome.json` deliberately scopes that to maintained web and JS/TS
sources, excluding generated bundles, build outputs, vendored trees and review-tool
metadata. Formatting and import sorting are off for now, so do not wire this into
required CI until the remaining source lint diagnostics are paid down.

## Tests and CI

Go up the [verification ladder](docs/contributor-verification.md) as far as your
change needs: source checks, the owning package's tests, compiling the app and
tests, then runtime and physical checks. In the pull request, say which of those
you ran. A parse or a build is not a test run.

**You do not need to run the app-host or UI tests on your own Mac.** They launch
the app and need a disposable GUI session. If you can't run them, open the pull
request anyway and say so under Testing. Opening the pull request is the request
for CI:

- Static checks run on every pull request. The Linux guards run when your diff
  touches what they cover.
- Swift, package, app-host and tooling tests are routed from your diff: an edited
  suite runs, and an app-source change runs the suites whose tests mention what
  you changed. No label needed.
- The broad macOS suite is label-gated. A maintainer adds `full-ci` when a change
  needs it ([PR CI coverage](skills/cmux-testing/references/pr-ci-coverage.md)).
  It is not a merge requirement.
- No pull request job runs `cmuxUITests/` in full. If you touch that directory, the
  `suite-coverage` check stays red until a maintainer runs the affected classes and
  records it with `no-full-ci`.
- On your first pull request, checks wait for a maintainer to approve the workflow
  run. That's a GitHub default for new contributors, not a judgement on the patch.

Read which tests actually ran on your commit, not the color of the checks list: a
skipped job is green and is not coverage.

## Ghostty Submodule

`ghostty` points to [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty),
our fork of Ghostty. To change it, rebuild `GhosttyKit.xcframework` or pull in
upstream, follow the [cmux-ghostty skill](skills/cmux-ghostty/SKILL.md): push the
submodule commit to the fork before committing the pointer here. Fork changes and
conflict notes are in [docs/ghostty-fork.md](docs/ghostty-fork.md).

## Pull Requests

- One change per pull request. A fix plus a reformat is two pull requests.
- Fill in the template: a summary of the problem and what someone can do after
  the change, and Testing with the commands you ran.
- For a bug fix, commit the failing regression test before the fix
  ([regression commits](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
- Under `## Changelog`, write one `Added`/`Changed`/`Fixed`/`Removed` line for a
  user-visible change, or `none`. Don't edit [CHANGELOG.md](CHANGELOG.md); releases
  build it from these lines.
- Localize user-facing strings ([localization skill](skills/cmux-localization/SKILL.md)).
- No unrelated formatting, generated files, vendored trees or version bumps.
- Sign the [CLA](CLA.md) once by commenting
  `I have read the CLA Document v2.2 and I hereby sign the CLA` on your pull request.
  The check matches commit author emails to your GitHub account, so commit with an
  email linked to it.

Merges are squash merges, so the title and description become the commit that
ships. How review works and what makes a patch wait is in
[start here](docs/start-here.md#5-what-happens-next).

Agents working in this repository also follow [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`).

## License

By contributing to this repository, you agree that:

1. Your contributions are licensed under the license of the directory you contribute to: the Business Source License 1.1 (`BUSL-1.1`) for the server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`, `workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`, `cmux-tui/relays/cloudflare-do/`), and the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`) everywhere else unless a file states otherwise.
2. You grant Manaflow, Inc. a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, sublicense, and distribute your contributions under any license, including a commercial license offered to third parties.
