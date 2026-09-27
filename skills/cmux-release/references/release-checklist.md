# Release Checklist

The command sequence lives in [../SKILL.md](../SKILL.md). This covers judgment calls and failure triage.

## Version policy

Minor bump by default. Patch or major only when explicitly requested or clearly justified by the release scope.

## Changelog

Keep `CHANGELOG.md` user-facing: user-visible fixes, behavior changes, and compatibility notes rank above internal refactors.

The PR Changelog lines are drafts. Edit them for tone and merge related lines, but keep each PR link. Before the release PR merges, show the human every `check-title` and `check-line` PR, every `revert-of-` row, and every first-parent commit without a PR number.

## Failure triage

- `release-pretag-guard.sh` fails on a non-monotonic build number: run `./scripts/bump-version.sh`, commit the bump, retry.
- Release automation fails **before** signing: inspect workflow configuration and version metadata.
- Release automation fails **during** signing or notarization: inspect secret availability and Apple account status.

## Asset rename

If `cmux-macos.dmg` is ever renamed, update every surface that assumes the `releases/latest/download/cmux-macos.dmg` path (README, website, updater feed, Homebrew formula).
