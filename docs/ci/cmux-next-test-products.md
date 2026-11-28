# Share a CmuxNext test build within one CI run

The Swift, daemon and generated-files jobs each run `swift build --build-tests`.
`scripts/ci/swiftpm_test_product.py` supplies an exact-run transport contract for
a later producer/consumer pilot. This change does not alter the workflow or
upload artifacts. Portable tests prove archive handling; a hosted macOS probe
must establish SwiftPM runtime compatibility and whether transfer saves time.

## Product and compatibility

The candidate product is a private copy of one completed SwiftPM scratch
directory: test executables, resource bundles, binary artifacts, resolved
dependency source, and graph/build metadata. Root `repositories` and `downloads`
caches and every nested `.git` entry are excluded. Git configs and repository
credentials are not part of a test product. Relative framework symlinks must
resolve entirely within the archive. External links, unsupported entry types,
duplicate or escaping paths, incomplete products and corrupt bytes are misses.

The manifest records every entry and each file's SHA-256, size and mode. It also
binds the product to the run and attempt, source remote/revision/tree, clean
tracked source, exact Xcode/Swift/SDK, architecture, configuration, supported
build arguments and relevant environment. Content hashes of all materialized
files under `Packages` include ignored web bundles and generated resources in
the app and its local macOS/iOS/shared package dependencies; nested `.build`
and `.git` directories are excluded. Seal and restore recheck the live source
revision and those materialized inputs. The Swift identity probes the actual
`swift` executable on PATH used by the build, including its resolved path.

Both checkout and scratch paths must match exactly. Tests use `#filePath` to
find repository fixtures and scripts, and SwiftPM graph metadata contains
absolute paths. Matching nominal paths on two runners does not establish that
their storage is independent: two runner processes can share a host.

Restore therefore requires an absent destination and claims it exclusively
after validation. It never removes or replaces an existing directory or symlink,
including a dangling warm `.build` link. Each successful consumer owns a separate
local copy of `build.db`; producer and consumer database writes are independent.
The producer must hold its build lane's normal lifetime lease and finish the
build successfully before sealing. This helper does not acquire fleet jobs or
authorize changes to another runner's scratch directory.

## Pilot commands

Choose a run-specific scratch path outside the package input directories, such
as `$GITHUB_WORKSPACE/.cmux-ci/test-products/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT`.
Use that same absolute path for every build/test command on a compatible runner.
An occupied path is an ordinary-build fallback, not a request to delete it.

Prepare the web/resources first, then capture identity **before** the native
build. Build with that exact command, compile the scratch directory's catalogs,
and seal only after success. Capturing a new identity after a build could bind
old compiled bytes to a later source overlay. All native commands below run on
a hosted CI/fleet worker, from the repository root:

```sh
set -euo pipefail
package="$GITHUB_WORKSPACE/Packages/macOS/CmuxNext"
flags_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
  --build-tests --package-path "$package" --scratch-path "$scratch")"
python3 scripts/ci/swiftpm_test_product.py identity \
  --scratch "$scratch" --flags-json "$flags_json" > producer-identity.json
swift build --build-tests --package-path "$package" --scratch-path "$scratch"
bin="$(swift build --package-path "$package" --scratch-path "$scratch" --show-bin-path)"
CMUX_SWIFT_BIN_PATH="$bin" scripts/cmux-next/compile-string-catalogs.sh
python3 scripts/ci/swiftpm_test_product.py seal \
  --scratch "$scratch" --identity producer-identity.json --archive test-product.tar.gz
```

`--flags-json` records the actual build argument vector. Include configuration,
jobs or debug-info arguments too when used. Custom toolchain/compiler/linker/search-path options
and custom compiler environments are unsupported in the first contract.

Every consumer must capture its own identity from its checked-out source,
materialized web/resources, toolchain and intended scratch path. Do not reuse the
producer's identity file as consumer compatibility evidence. Obtain the archive
SHA-256 from the trusted same-run producer output; the helper does not discover
or authorize remote artifacts.

```sh
python3 scripts/ci/swiftpm_test_product.py identity \
  --scratch "$scratch" --flags-json "$flags_json" > consumer-identity.json
python3 scripts/ci/swiftpm_test_product.py restore \
  --scratch "$scratch" --identity consumer-identity.json \
  --archive test-product.tar.gz --sha256 "$producer_sha256"
```

Operations return JSON. `sealed` includes compressed bytes and SHA-256;
`validated`/`restored` includes expanded bytes. A rejected operation returns
`outcome: miss` and exits 1. A workflow must run its ordinary build on a miss and
run the consumer's tests regardless of product reuse. Test outcomes are never
reused.

## Hosted acceptance before workflow integration

First compare the candidate shape against an ordinary exact-head build using
the existing hang sampler and `swift test --skip-build --scratch-path ...`.
Retain the consumer's full discovery/execution and hang/crash evidence. Removing
checkout VCS metadata may make SwiftPM re-resolve dependencies even with
`--skip-build`; that behavior has not been established by portable fixtures.
If it does, narrow the product to runtime bundles plus producer-generated test
discovery and adapt the existing direct-bundle runner while preserving Next's
sampler. Do not ship Git configs to avoid a re-resolution.

The stock build's runtime libraries must come from the matching package inputs,
scratch, Xcode/SDK or system environment. Arbitrary external runtime dependencies
are outside this contract; there is no binary-format dependency scanner.

Record build wall/CPU time, compressed/expanded bytes, seal/upload/download/
validation/extraction time, and producer/consumer queue delays. Compare these
with warm builds, including no-op builds: transferring a scratch snapshot can
cost more than the compile it avoids. Enable actual sharing only after native
execution and those measurements support the selected payload shape.
