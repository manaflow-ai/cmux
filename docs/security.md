# Security scanning

cmux uses the `Snyk security` GitHub Actions workflow for rollout-safe security review on pull requests and pushes to `main`.

## What runs

- Snyk Code runs SAST against cmux Swift sources at `high` severity and above.
- Snyk Open Source runs SCA against the docs site manifest at `web/package.json` at `high` severity and above.

The v1 SCA scope is npm only. The workflow runs `bun install --frozen-lockfile --ignore-scripts` first, then tells Snyk to treat `web/package.json` as an npm project. Lifecycle scripts stay disabled during install because the later SCA step receives `SNYK_TOKEN`. Until Snyk supports `bun.lock` directly, Snyk resolves dependencies from the installed `web/node_modules` snapshot rather than parsing the Bun lockfile itself.

Swift Package Manager dependencies are resolved through `cmux.xcodeproj/project.pbxproj` and `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` instead of a top-level `Package.swift` or root `Package.resolved`, so SPM SCA needs a follow-up design before enabling.

## Where findings appear

The workflow writes SARIF for each scanner and uploads it with `github/codeql-action/upload-sarif`. GitHub shows those results in code scanning, the repository Security tab, and inline PR annotations. After the Snyk GitHub App is installed for the `manaflow-ai/cmux` repository, Snyk App comments may also appear on PRs.

## Fork PR behavior

The workflow does not run Snyk scans unless `SNYK_TOKEN` is available. Fork PRs, Dependabot PRs, and the initial rollout period before the secret is added produce a clean skip instead of a red CI result.

## Ignores

Use `.snyk` for reviewed, temporary ignores. Prefer fixing the finding first. If an ignore is necessary, add it with an expiry and a concrete reason:

```bash
snyk ignore --id=<SNYK-ID> --expiry=YYYY-MM-DD --reason="why this is safe until the expiry"
```

Keep ignores narrow, expiring, and reviewed in the PR that adds them.
