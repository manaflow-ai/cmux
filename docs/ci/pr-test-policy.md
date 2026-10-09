# PR test-suite policy

The presence of a test does not make it an every-PR check. The policy in
[`config/ci-test-suites.json`](../../config/ci-test-suites.json) assigns each
product-test root to a platform aggregate and a PR mode.

`selective` suites are eligible when the changed source or test path matches the
suite's roots. A suite can exclude a narrower source root when a broad source
tree is shared by two products; for example, macOS excludes `Sources/Mobile/`.
`off` is for tests that run only manually, nightly, or in a release lane.
`always` is reserved for small, stable checks that every change needs. A new
test under a known root inherits that root's policy; a new test under an
unknown product-test root fails the policy guard until its owner adds an
explicit suite entry.

The same fail-closed rule applies to a changed file under a product root that
has no owning suite. Add the source and test roots to the manifest together so
the aggregate selection remains reviewable.

For a normal test addition, place the file under an existing owned root and let
that root's `selective` policy route it. An agent does not need to ask whether
each individual test should run on PRs. It should ask when the test needs a new
root, a new suite, or an `always`/`off` decision; those choices change coverage
or the PR budget and need an owner. The policy guard then makes the decision
visible in the review.

The stable checks are the aggregate jobs in [`pr-checks.yml`](../../.github/workflows/pr-checks.yml):
`Shared`, `macOS`, `iOS`, `Web`, and `Status`. The current platform jobs are
noops. They record the route selected by the manifest so real leaf suites can be
attached later without changing branch-protection contexts.

Regression tests use the same ownership model as feature tests. A macOS
regression belongs to a macOS suite, an iOS regression to an iOS suite, and a
web regression to a web suite; the platform aggregate reports the selected
result. There is no separate regression aggregate to run for every change.

Individual suites and shards should remain non-required implementation details.
The aggregate owns the result and reports a successful, explicit skip when its
platform has no selected suite. A selector that cannot safely classify a diff
must widen coverage or fail routing; it must not silently claim that nothing
needs to run.

When branch protection is enabled for this workflow, require only
`PR checks / Status`. The platform aggregates stay visible for diagnosis, while
leaf suite names can change as coverage grows without requiring a ruleset edit
for every new test lane.
