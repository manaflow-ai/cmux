# cmux TUI Distribution Release

The cmux TUI distribution uses `cmux-tui-vX.Y.Z` tags. The npm launcher
package, npm platform packages, and PyPI wheels all share the same `X.Y.Z`
version for a release.

TUI distribution versions are independent of the SDK version. The SDK package
relocation to `cmux-sdk` is tracked separately and is not part of this release
path.

The TUI does not store its version in a checked-in manifest. The packaging
scripts receive `--version`, so cutting a stable TUI release is just creating a
`cmux-tui-vX.Y.Z` tag on `main`.

## Packages

- npm `cmux`: launcher package for `npx cmux`.
- npm `cmux-tui-darwin-arm64`: macOS arm64 binary package.
- npm `cmux-tui-darwin-x64`: macOS x64 binary package.
- npm `cmux-tui-linux-x64`: Linux x64 binary package.
- npm `cmux-tui-linux-arm64`: Linux arm64 binary package.
- PyPI `cmux`: platform wheels for `uvx cmux` / `pipx run cmux`.

## One-time registry setup

Add npm Trusted Publishers for all five npm package names:

- `cmux`
- `cmux-tui-darwin-arm64`
- `cmux-tui-darwin-x64`
- `cmux-tui-linux-x64`
- `cmux-tui-linux-arm64`

Use these npm trusted-publisher settings for each package:

- Repository: `manaflow-ai/cmux`
- Workflow: `tui-publish-npm.yml`
- Environment: `npm-tui`

Add a PyPI Trusted Publisher for:

- Project: `cmux`
- Repository: `manaflow-ai/cmux`
- Workflow: `tui-publish-pypi.yml`
- Environment: `pypi-tui`

Nightly publishing uses the same environments. Add trusted publishers for:

- npm packages:
  - Repository: `manaflow-ai/cmux`
  - Workflow: `tui-nightly.yml`
  - Environment: `npm-tui`
- PyPI project `cmux`:
  - Repository: `manaflow-ai/cmux`
  - Workflow: `tui-nightly.yml`
  - Environment: `pypi-tui`

## Nightly channel

`.github/workflows/tui-nightly.yml` runs on a daily schedule and by manual
dispatch. It always checks out `main`, derives the next stable version from the
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

Use `.github/workflows/tui-release-cut.yml` from `main`.

- Select `patch`, `minor`, or `major`, or provide an explicit `X.Y.Z` version.
- The workflow reads the latest reachable `cmux-tui-vX.Y.Z` tag, validates the
  new version is strictly greater, creates annotated tag `cmux-tui-vX.Y.Z` on
  `main` HEAD, and pushes that tag.
- The tag is pushed with the default `GITHUB_TOKEN`, and GitHub suppresses
  workflow triggers for token-created events, so the release-cut workflow then
  explicitly dispatches `mux-tui-release.yml` (build + package) and
  `tui-publish-pypi.yml` (PyPI wheels) against the new tag. A manual
  `git push origin cmux-tui-vX.Y.Z` from a developer machine still fires both
  tag triggers directly.
- npm remains dispatch-gated. After the tag cut, manually dispatch
  `tui-publish-npm.yml` with the same `X.Y.Z` version and
  `confirm_tui_cmux=true`.

## Publishing

PyPI publishing can run from `cmux-tui-vX.Y.Z` tags or manual dispatch.

npm publishing is manual dispatch only and requires `confirm_tui_cmux=true`.
The platform packages are published first, then the `cmux` launcher.

The npm launcher publish deliberately does not pass `--tag`: when the TUI
version is greater than `0.8.3`, this coordinated release takes over the npm
`latest` dist-tag for `cmux` from the old CLI package.
