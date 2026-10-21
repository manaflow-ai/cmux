# Stack Auth Swift SDK vendoring record

## Origin

- Upstream repository: https://github.com/stack-auth/swift-sdk-prerelease
- Base revision: `784d147c4c0510c33f591d13b7a1142bbf094c65`
  (`Release v2.8.72`, 2026-03-10).
- First cmux import: `d56cf9bc0bdb62351ba7770f3beb860b43070798`
  (2026-04-19).

The initial cmux tree retained the upstream package manifest, README, sources,
tests, and `.gitignore`. It omitted `Examples/`, the upstream
`Package.resolved`, and `Sources/StackAuth/Sentinels.swift`.

The following files already differed from the upstream base in the first cmux
import and are therefore part of the cmux patch set:

- `Sources/StackAuth/APIClient.swift`
- `Sources/StackAuth/Models/User.swift`
- `Sources/StackAuth/StackClientApp.swift`
- `Tests/StackAuthTests/OAuthTests.swift`
- `Tests/StackAuthTests/TestConfig.swift`

Subsequent changes are maintained directly in this repository. Use
`git log -- vendor/stack-auth-swift-sdk-prerelease` as the patch ledger; do not
replace this directory with an upstream snapshot and silently drop those
changes.

## License status

No upstream license file exists at the recorded base revision, and GitHub
reported no detected license for the upstream repository on 2026-10-20. This
record does not invent or grant a license. Do not import newer upstream bytes
until the owner has confirmed the applicable permission and recorded its text
or reference here.

## Updating

1. Fetch the upstream repository into a temporary checkout and select the exact
   reviewed revision; never copy a moving branch.
2. Compare that revision with this directory and classify every upstream and
   cmux-only change. Preserve the patch files above unless a reviewed change
   deliberately supersedes them.
3. Copy only the reviewed files, update the base revision and the retained,
   omitted, and patched-file inventories in this record, and add the confirmed
   license or permission reference.
4. Resolve every affected standalone `Package.resolved`, run the StackAuth and
   auth-runtime package tests, and review the resulting source diff before
   committing.
