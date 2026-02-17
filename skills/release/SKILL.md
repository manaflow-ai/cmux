---
name: release
description: Prepare and ship a cmux release end-to-end: choose the next version, curate user-facing changelog entries, bump versions, open and monitor a release PR, merge, tag, and verify published artifacts. Use when asked to cut, prepare, publish, or tag a new release.
---

# Release

Run this workflow to prepare and publish a cmux release.

## Workflow

1. Determine the version:
- Read `MARKETING_VERSION` from `GhosttyTabs.xcodeproj/project.pbxproj`.
- Default to a minor bump unless the user explicitly requests patch/major/specific version.

2. Create a release branch:
- `git checkout -b release/vX.Y.Z`

3. Gather user-facing changes since the last tag:
- `git describe --tags --abbrev=0`
- `git log --oneline <last-tag>..HEAD --no-merges`
- Keep only end-user visible changes (features, bug fixes, UX/perf behavior).

4. Update changelogs:
- Update `CHANGELOG.md`.
- Update `docs-site/content/docs/changelog.mdx`.
- Use categories `Added`, `Changed`, `Fixed`, `Removed`.
- If no user-facing changes exist, confirm with the user before continuing.

5. Bump app version metadata:
- Prefer `./scripts/bump-version.sh`:
  - `./scripts/bump-version.sh` (minor)
  - `./scripts/bump-version.sh patch|major|X.Y.Z`
- Ensure both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are updated.

6. Commit and push branch:
- Stage release files (changelog + version updates).
- Commit with `Bump version to X.Y.Z`.
- `git push -u origin release/vX.Y.Z`.

7. Create release PR:
- `gh pr create --title "Release vX.Y.Z" --body "..."`
- Include a concise changelog summary in the PR body.

8. Watch CI and resolve failures:
- `gh pr checks --watch`
- Fix failing checks, push, and wait for green.

9. Merge and sync `main`:
- `gh pr merge --squash --delete-branch`
- `git checkout main && git pull --ff-only`

10. Create and push tag:
- `git tag vX.Y.Z`
- `git push origin vX.Y.Z`

11. Verify release workflow and assets:
- `gh run watch --repo manaflow-ai/cmux`
- Confirm release exists in GitHub Releases and includes `cmux-macos.dmg`.

## Changelog Rules

- Include only user-visible changes.
- Exclude internal-only changes (CI, tests, docs-only edits, refactors without behavior changes).
- Write concise user-facing bullets in present tense.

