# Reuse Swift package test products within a PR run

Leo: “The cpu time is the true cost” and “we should probably just get these cuts in asap”.

On eligible PRs targeting a branch other than `feat-cmux-next`, `swift-test`, `daemon-test`,
and the generated-files Mac fallback can each run the same unfiltered
`swift build --build-tests` in `Packages/macOS/CmuxNext`. Their different test filters
do not change that build command. The normal NEXT PR exclusions remain in place.

The jobs form an ordered relay. Existing reuse receipts still skip compilation.
The first job that actually builds publishes runtime products to the R2 artifact store;
later jobs restore those products and run their existing tests with `--skip-build`.
This changes **2–3 equivalent build invocations → 1** in the overlap case. It is a
structural count, not a measured CPU or wall-time result. The dependency order can
increase wall time; it deliberately avoids eager builds when all test receipts hit.

Product outputs describe successful upload or restore separately from test results.
A failing test suite therefore does not prevent later independent suites from using
the successful products. Compilation, packing, upload, download, or validation failure
never falls back to another same-run compile. If an earlier job did not build, the next
eligible job can become the producer. A successful Linux generated-files verdict still
suppresses the Mac fallback.

The manifest binds products to source SHA/tree, run, repository, package/profile,
actual Swift/Xcode/SDK versions, developer directory, architecture, and graph flags.
Consumers use the producer's artifact name so a failed-job rerun can use an artifact
from the original attempt. Runtime paths are relocated using equal-length aliases;
modified Mach-O products are re-signed. Compiler objects and modules are not shipped.

`tests/test_swift_test_products.py` checks the relay DAG, job predicates, failure
states, product identities, archive boundaries, and cross-checkout runtime relocation.
The synthetic restore reports `compiled=0`; it is not native macOS execution evidence.
Native artifact consumption and five real PR CPU/wall measurements are still required
before claiming measured savings.
