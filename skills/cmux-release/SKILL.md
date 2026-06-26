---
name: cmux-release
description: "cmux release workflow, version bumping, Keep a Changelog release-note summaries from git log input, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing release notes, preparing a release, or troubleshooting a cmux release."
---

# cmux Release

Use the `/release` command to prepare a new release. This will:

1. Determine the new version (bumps minor by default)
2. Gather commits since the last version tag
3. Draft user-facing release notes in Keep a Changelog 1.1.0 style
4. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
5. Run `./scripts/bump-version.sh` to update both versions
6. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

## Release notes

Use the commit log as raw input, not final copy:

```bash
git fetch --tags origin
previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*')"
git log --first-parent --reverse --oneline "${previous_tag}..HEAD"
```

Summarize notable user-facing changes into the existing `CHANGELOG.md` format:

- Use `### Added`, `### Changed`, `### Deprecated`, `### Removed`, `### Fixed`, and `### Security`; omit empty sections.
- Convert PR titles and commit subjects into clear outcomes for users.
- Preserve PR links and community contributor credit when available.
- Skip purely internal churn unless it affects users, compatibility, release assets, performance, or reliability.
- Mention beta platform scope explicitly, such as `iOS (beta):`.

## Version bumping

```bash
./scripts/bump-version.sh
./scripts/bump-version.sh patch
./scripts/bump-version.sh major
./scripts/bump-version.sh 1.0.0
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

Manual release steps if not using the command:

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

## Notes

- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Bump the minor version for updates unless explicitly asked otherwise.
- Update `CHANGELOG.md`; docs changelog is rendered from it.

## Detailed reference

- Read [references/release-checklist.md](references/release-checklist.md) for the detailed release checklist, changelog authoring workflow, and common failure handling.
