# cmux TUI Distribution Release

The cmux TUI distribution uses `cmux-tui-vX.Y.Z` tags. The npm launcher
package, npm platform packages, and PyPI wheels all share the same `X.Y.Z`
version for a release.

TUI distribution versions are independent of the SDK version. SDKs publish as
`cmux-sdk` on npm and PyPI, so the `cmux` name remains exclusive to this TUI
release path.

The TUI does not store its version in a checked-in manifest. The packaging
scripts receive `--version`, so cutting a stable TUI release is just creating a
`cmux-tui-vX.Y.Z` tag on `main`.

## Packages

- npm `cmux`: launcher package for `npx cmux`.
- npm `cmux-tui-darwin-arm64`: macOS arm64 binary package.
- npm `cmux-tui-darwin-x64`: macOS x64 binary package.
- npm `cmux-tui-linux-x64`: Linux x64 binary package.
- npm `cmux-tui-linux-arm64`: Linux arm64 binary package.
- npm `cmux-relay`: launcher for the chatmux machine relay. Built and
  validated with every TUI release, but published ONLY through the
  `cmux-relay-vX.Y.Z` tag family (`relay-publish-npm.yml`).
- npm `cmux-relay-*`: Unix platform relay binary packages. Each package
  contains the matching `cmux-tui` runtime, and the launcher sets
  `CHATMUX_RELAY_CMUX_TUI` to that exact bundled binary. The relay release is
  five packages total (one launcher plus four Unix targets); it does not rely
  on a separately published TUI package and must not silently degrade to a
  shell.
- Windows TUI packages can still be built when the general release input
  `include_windows` is enabled. Stable and nightly releases default to Unix
  until the experimental Windows package's registry publisher is configured;
  the launcher advertises only the platforms included in its package set.
  The stable Rust machine-relay workflow excludes
  Windows because `chatmux-relay` has no tested Windows PTY backend. Keep the
  chatmux Node relay as the Windows rollback lane until that backend exists.
- PyPI `cmux`: platform wheels for `uvx cmux` / `pipx run cmux`.

Relay autostart needs a durable native executable. `npx cmux-relay
--autostart` is refused when npm resolves the relay from its disposable
`_npx` cache, because npm can remove that directory after the command exits.
Install the package globally (`npm install --global cmux-relay`) or in a
persistent project, then run `cmux-relay --autostart`.

Linux packages contain static musl binaries that run on both glibc and musl
distributions. PyPI publishes each Linux binary under matching manylinux and
musllinux wheel tags so installers on both runtime families can resolve it.

Before upload, the package contract validator checks the exact npm package
tree, including each TUI binary and hook and each relay package's bundled TUI
runtime. It then runs `npm pack` and an offline install of the matching Linux
packages. It checks the exact six PyPI wheels, their platform tags, metadata,
`RECORD` hashes, and executable modes. PyPI remains Unix-only.

## One-time registry setup

Add npm Trusted Publishers for the cmux TUI package names:

- `cmux`
- `cmux-tui-darwin-arm64`
- `cmux-tui-darwin-x64`
- `cmux-tui-linux-x64`
- `cmux-tui-linux-arm64`
- `cmux-tui-win32-x64`

Use these npm trusted-publisher settings for each package:

- Repository: `manaflow-ai/cmux`
- Workflow: `tui-publish-npm.yml`
- Environment: `npm-tui`

The cmux-relay package names publish through their own tag family
(`cmux-relay-vX.Y.Z`, workflow `relay-publish-npm.yml`) and need their own
trusted publishers:

- `cmux-relay`
- `cmux-relay-darwin-arm64`
- `cmux-relay-darwin-x64`
- `cmux-relay-linux-x64`
- `cmux-relay-linux-arm64`

with:

- Repository: `manaflow-ai/cmux`
- Workflow: `relay-publish-npm.yml`
- Environment: `npm-tui`

The `cmux-relay` launcher name itself is owned by the chatmux repo's Node
publisher until the relay Rust cutover (chatmux `docs/RELAY-RUST.md`): move
its trusted publisher to this repository before the first stable
`cmux-relay-vX.Y.Z` tag. Release candidates (`cmux-relay-vX.Y.Z-rc.N`)
publish under the `next` dist-tag; stable relay tags take `latest`, which IS
the production cutover flip — coordinate with the chatmux repo variable
`CHATMUX_RELAY_PUBLISH_MODE=external-rust` so the Node publisher stands down
first. The coordinated TUI publish and the nightly lane validate the relay
package contract but never publish or move relay dist-tags.

Do not configure or publish `cmux-relay-win32-x64` for the Rust cutover. The
Node publisher must remain available for Windows until a tested Rust Windows
PTY backend and its own capability contract are approved.

Add a PyPI Trusted Publisher for:

- Project: `cmux`
- Repository: `manaflow-ai/cmux`
- Workflow: `tui-publish-pypi.yml`
- Environment: `pypi-tui`

Nightly publishing uses the same environments. Add trusted publishers for:

- npm packages:
  - Repository: `manaflow-ai/cmux`
  - Workflow: `cmux-tui-nightly.yml`
  - Environment: `npm-tui`
- PyPI project `cmux`:
  - Repository: `manaflow-ai/cmux`
  - Workflow: `cmux-tui-nightly.yml`
  - Environment: `pypi-tui`

## Nightly channel

`.github/workflows/cmux-tui-nightly.yml` runs by manual dispatch. Automatic
scheduling is currently paused. It always checks out `main`, derives the next stable version from the
latest reachable `cmux-tui-vX.Y.Z` tag by bumping patch, and falls back to
`0.9.0` when no stable TUI tag exists.

Nightly versions use registry-specific prerelease forms:

- npm: `<next-stable>-nightly.<YYYYMMDD>.<run-number>`, for example
  `0.9.1-nightly.20260708.1`.
- PyPI: `<next-stable>.dev<YYYYMMDD><run-number>`, for example
  `0.9.1.dev202607081`.

npm nightlies are published with `npm publish --provenance --tag nightly`, so
`npx cmux@nightly` opts into the latest nightly and `npx cmux` remains on the
stable `latest` dist-tag. PyPI nightlies are dev releases, so normal
`uvx cmux` resolution ignores them; `uvx --prerelease allow cmux` opts in.

The nightly workflow intentionally always builds and publishes a fresh run
instead of trying to skip when `main` has not changed. The build is cheap, and a
GitHub API lookup for the last successful nightly is more fragile than the
extra build.

## Cutting a Stable Release

Release tags require the maintainer identity under the repository's
`release tags: Lawrence only (tag-is-consent)` ruleset. The release-cut
workflow's default `GITHUB_TOKEN` cannot create them. Keep that protection:
create and push an annotated `cmux-tui-vX.Y.Z` tag on the selected `main`
revision using the maintainer's authenticated Git client. The tag push runs
`cmux-tui-release.yml` without publishing. Once it succeeds, dispatch
`tui-publish-npm.yml` and `tui-publish-pypi.yml` on that exact tag, passing the
version and successful artifact run ID (and `confirm_tui_cmux=true` for npm).
Complete both environment approvals, then verify registry delivery below.

The older `.github/workflows/cmux-tui-release-cut.yml` flow can still recover
the coordinated dispatch when the tag already exists at the workflow's source
revision. Its tag-creation step requires a publishing identity permitted by
the ruleset and otherwise fails:

- Select `patch`, `minor`, or `major`, or provide an explicit `X.Y.Z` version.
- The workflow reads the latest reachable `cmux-tui-vX.Y.Z` tag, validates the
  new version is strictly greater, creates annotated tag `cmux-tui-vX.Y.Z` on
  `main` HEAD, and pushes that tag.
- The tag is pushed with the default `GITHUB_TOKEN`, and GitHub suppresses
  workflow triggers for token-created events, so the release-cut workflow then
  explicitly dispatches `cmux-tui-release.yml` against the new tag with npm and
  PyPI publishing enabled.
- `cmux-tui-release.yml` builds every target once, creates both registries'
  packages, and runs the Linux compatibility matrix. After those jobs pass, it
  dispatches both top-level publishers with its own artifact run ID. This keeps
  the configured trusted-publisher identities while avoiding registry-specific
  rebuilds.
- A manual `git push origin cmux-tui-vX.Y.Z` runs the artifact workflow without
  publishing. Use the release-cut workflow for a coordinated stable release.

A successful release-cut or artifact run does not mean users received the
release. Follow both publisher runs through their environment approvals and
post-upload verification. `cmux-tui registry delivery` independently compares
the newest stable tag with PyPI and npm, including all six non-yanked PyPI
wheels. It runs after artifact completion and every six hours, with a two-hour
grace period for compilation and approval. It never approves or publishes
anything. This separate check avoids the circular wait between the artifact
run and the publishers that require that run to have completed.

For a local delivery check, run
`python3 cmux-tui/scripts/check_release_delivery.py --grace-seconds 0`.
After delivery, verify a clean `uvx --refresh cmux@latest` installation. An
existing `uv tool install cmux==X.Y.Z` takes precedence for plain `uvx cmux`;
replace that pin with `uv tool install --upgrade cmux` to update it. Session
state written by newer development versions can require a newer stable
package. Keep development runs in a dedicated `--session` instead of `main`;
never reset personal state to make an older package start.

## Publishing

Both registry workflows are manual-dispatch only. They require the ID of a
successful `cmux-tui-release.yml` run on the exact release tag. Each publisher
checks the source workflow, tag, commit, and conclusion before downloading its
package artifact. It never rebuilds the binaries. This also lets a failed
publisher retry reuse the already verified artifacts.

npm additionally requires `confirm_tui_cmux=true`. The platform packages are
published first, then the `cmux` launcher.

The shared artifact run exercises the generated npm and PyPI entrypoints across
the supported glibc and musl distribution matrix on x86_64 and ARM64. A
compatibility regression therefore blocks both registry dispatches.

The npm launcher publish deliberately does not pass `--tag`: when the TUI
version is greater than `0.8.3`, this coordinated release takes over the npm
`latest` dist-tag for `cmux` from the old CLI package.
