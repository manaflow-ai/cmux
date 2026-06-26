# Release Checklist

This reference expands the cmux release workflow.

## Default path

Prefer the `/release` command. It should handle:

- choosing the version
- gathering commits since the last tag
- drafting Keep a Changelog release notes from the commit log
- updating `CHANGELOG.md`
- running `./scripts/bump-version.sh`
- committing release metadata
- running `./scripts/release-pretag-guard.sh`
- tagging and pushing

## Version policy

Use a minor bump by default. Use patch or major only when explicitly requested or clearly justified by the release scope.

The version bump script updates both:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

The build number must increase for Sparkle auto-update. If `release-pretag-guard.sh` fails because the build number is not monotonic, run the bump script, commit the build-number bump, and retry the guard.

## Changelog

Update `CHANGELOG.md`. The docs changelog page at `web/app/docs/changelog/page.tsx` renders from it, so do not update a separate docs changelog source.

cmux follows the [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) shape: the newest release first, `YYYY-MM-DD` dates, and grouped change types. Use these section names when they apply:

- `### Added` for new features, commands, settings, integrations, or platform capabilities
- `### Changed` for behavior changes, UI polish, performance work, compatibility changes, and notable dependency/tooling changes that affect users
- `### Deprecated` for soon-to-be removed features
- `### Removed` for removed features, settings, commands, or UI
- `### Fixed` for bug fixes, crashes, regressions, reliability work, and compatibility repairs
- `### Security` for vulnerability fixes or security hardening users should notice

Omit empty sections.

### Release note input

For an in-progress release, gather the raw commit input from the last version tag to `HEAD`:

```bash
git fetch --tags origin
previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*')"
git log --first-parent --reverse --oneline "${previous_tag}..HEAD"
```

For an already tagged release candidate, compare the previous version tag to the current tag:

```bash
current_tag="vX.Y.Z"
previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${current_tag}^")"
git log --first-parent --reverse --oneline "${previous_tag}..${current_tag}"
```

Use `--first-parent` by default so merge commits and PR titles provide a compact release history. If the release includes direct commits or a title is ambiguous, inspect the PR or the full commit range before writing the note.

### Writing release notes

Treat `git log` as source material, not as copy to paste. Keep the changelog user-facing. Mention user-visible fixes, new behavior, compatibility notes, performance improvements, and release-asset changes more prominently than internal refactors.

Quality bar:

- Rewrite "Fix ..." or raw PR titles into the outcome users care about.
- Keep each bullet specific enough to tell users what changed, but short enough to scan.
- Preserve PR links in the existing `([#1234](https://github.com/manaflow-ai/cmux/pull/1234))` style.
- Preserve "thanks @user" credit for community contributors when the PR or existing changelog context provides it.
- Combine closely related PRs into one bullet when that reads better than separate near-duplicates.
- Call out platform scope at the start of the bullet when relevant, such as `iOS (beta):`.
- Skip purely internal refactors, CI-only churn, and dependency bumps unless they affect users, compatibility, security, release assets, performance, or reliability.
- Do not create a miscellaneous catch-all section.

## Tagging

Run before tagging:

```bash
./scripts/release-pretag-guard.sh
```

Manual tag flow:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

## Release asset

The expected release asset is:

```text
cmux-macos.dmg
```

The README download button points to:

```text
releases/latest/download/cmux-macos.dmg
```

If the asset name changes, update every surface that assumes this path.

## Required secrets

Release signing/notarization depends on:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

If release automation fails before signing, inspect workflow configuration and version metadata first. If it fails during signing/notarization, inspect the secret availability and Apple account status.
