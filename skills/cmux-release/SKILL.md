---
name: cmux-release
description: "cmux release workflow, version bumping, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing or troubleshooting a cmux release."
---

# cmux Release

Prefer the `/release` command. It determines the new version (minor by default), gathers the Changelog line from each PR merged since the last stable tag, updates `CHANGELOG.md`, runs `./scripts/bump-version.sh`, commits, runs `./scripts/release-pretag-guard.sh`, then tags and pushes.

## Changelog source

Feature PRs don't edit `CHANGELOG.md`. Each PR description has a `## Changelog` section with one user-facing line (`Added`, `Changed`, `Fixed`, or `Removed`, present tense) or `none`. At release time, [`/release` step 2](../../.claude/commands/release.md#shared-prep-all-three-release-commands) fetches every PR merged since the last `v*` tag in one GraphQL query and classifies it with [references/changelog-lines.jq](references/changelog-lines.jq):

- a Changelog line becomes an entry, with the PR link and `-- thanks @user!` for authors and reporters outside the core team (`lawrencecchen`, `austinywang`, `teamleaderleo`) and bots;
- `none` is skipped, and so is a PR undone by a revert later in the range (a reapply leaves it live);
- a revert of a PR that shipped in an earlier release gets its own line and is flagged for the human; reverts within the range are skipped;
- a PR with no section, or a line without an `Added`/`Changed`/`Fixed`/`Removed` prefix, is listed for the human to check.

The release then folds any leftover `## Unreleased` entries into the new version section and removes that heading.

The docs changelog page at `web/app/[locale]/(landing)/docs/changelog/page.tsx` renders from `CHANGELOG.md`, so there is no separate docs changelog source to update.

## Version bumping

```bash
./scripts/bump-version.sh          # minor (0.15.0 -> 0.16.0)
./scripts/bump-version.sh patch    # 0.15.0 -> 0.15.1
./scripts/bump-version.sh major    # 0.15.0 -> 1.0.0
./scripts/bump-version.sh 1.0.0    # explicit version
```

This updates `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number auto-increments and must increase for Sparkle auto-update to work. Bump the minor version unless explicitly asked otherwise.

## Tagging

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
# Use the run ID created by the tag push; the shared waiter observes it without polling GitHub.
glaeda-gh wait run manaflow-ai/cmux/<run-id>
```

If the pretag guard fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry.

## Release artifacts and secrets

- The release asset is `cmux-macos.dmg`, attached to the tag. The README download button points to `releases/latest/download/cmux-macos.dmg`.
- Signing requires the GitHub secrets `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD` and `APPLE_SIGNING_IDENTITY`. CI notarization authenticates with the team App Store Connect API key (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`) through `scripts/ci/lib/notary-auth.sh`, which decodes the key to a mode-600 temp file that the caller deletes. The local `scripts/build-sign-upload.sh` still uses an Apple ID and app-specific password.

## Detailed reference

- [references/release-checklist.md](references/release-checklist.md): changelog tone, failure triage, and asset-rename fallout.
