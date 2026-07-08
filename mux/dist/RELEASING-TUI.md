# cmux TUI Distribution Release

The cmux TUI distribution uses `cmux-tui-vX.Y.Z` tags. The npm launcher
package, npm platform packages, and PyPI wheels all share the same `X.Y.Z`
version for a release.

TUI distribution versions are independent of the SDK version. The SDK package
relocation to `cmux-sdk` is tracked separately and is not part of this release
path.

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

## Publishing

PyPI publishing can run from `cmux-tui-vX.Y.Z` tags or manual dispatch.

npm publishing is manual dispatch only and requires `confirm_tui_cmux=true`.
The platform packages are published first, then the `cmux` launcher.

The npm launcher publish deliberately does not pass `--tag`: when the TUI
version is greater than `0.8.3`, this coordinated release takes over the npm
`latest` dist-tag for `cmux` from the old CLI package.
