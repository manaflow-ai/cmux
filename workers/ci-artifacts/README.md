# Compiled-product artifact transport

This optional Worker shares an immutable GitHub Actions artifact through a
private R2 bucket. It changes transport, not build admission or test results.
It is disabled in CI until `CI_ARTIFACT_R2_URL` names a deployed broker origin.

The compile job still uploads its artifact to GitHub and publishes its artifact
ID and archive hash. The six app-host shards and runtime job try the broker
before the existing GitHub download action. Their existing restore code still
verifies the inner archive, source/toolchain receipts and producer warning log.
Both the current gzip archive and #13201's Apple Archive are opaque ZIP entries
to this transport; neither packaging implementation is changed here.

## Request and cache contract

`GET /v1/manaflow-ai/cmux/artifacts/<artifact-id>/<github-sha256>.zip`

- Only the fixed public `manaflow-ai/cmux` repository is accepted. GitHub must
  report the exact artifact ID/digest, an unexpired app-host product artifact,
  and a successful compile-admission job in its producing CI attempt. The
  overall CI run may still be active: its consumers need these bytes to finish.
- A Durable Object for the artifact ID/digest coalesces simultaneous misses.
  It streams one GitHub download into R2 with a fixed byte count and R2-verified
  SHA-256. No multi-hundred-megabyte JavaScript buffer or stream tee is used.
- Consumers receive bytes only after a verified R2 commit. A failed import
  aborts the upstream stream and waits for both transfer legs to settle before
  releasing import ownership. Consumer HTTP waits remain bounded even if an
  R2 binding call stalls; that does not permit overlapping orphan imports.
- Hits still check GitHub visibility/expiry/provenance. The bucket must remain
  private, without an R2 public domain or `r2.dev` access that bypasses these
  checks. This is separate from the existing public `ci-cache.cmux.com` store.
- Production callers present a short-lived GitHub Actions OIDC token with
  audience `cmux-ci-artifacts`. The Worker verifies GitHub's signature plus the
  repository ID, owner ID, public visibility, `ci.yml` workflow ref, event,
  run ID and token lifetime before touching artifact state. A global Durable
  Object admits at most 16 requests per run per minute and 120 total per minute.
  The Worker's server-only Actions-read token is sent only to `api.github.com`,
  never to redirected blob URLs. No R2 write credentials enter PR jobs. The
  consumer independently obtains the provider ZIP digest from GitHub, checks it,
  and extracts only one bounded, flat product archive.

The default import deadline is 150 seconds (`IMPORT_TIMEOUT_MS`, capped at
150000); R2 metadata/read calls have 10-second response deadlines. Production
caller authentication is bounded at five seconds and admission at two seconds.
The consumer's OIDC mint is bounded at 15 seconds, broker curl at 175 seconds,
and broker subprocess at 180 seconds. Its independent GitHub artifact metadata
lookup is bounded at 20 seconds. Errors, provider failures, checksum mismatches
and invalid ZIPs leave `hit=false` and use the existing GitHub action. Required
inner product validation remains authoritative.

## Enablement

The reviewed production configuration uses its `workers.dev` origin with preview
URLs disabled. The HTTP endpoint is internet-reachable; the artifact service is
private through GitHub-signed caller identity and the bucket itself has no public
R2 domain. The `REQUEST_ADMISSION` Durable Object provides the bounded request
budget before any artifact import can consume GitHub API quota.

Activation remains an administrator operation:

1. Merge this production-auth/measurement change and the isolated-canary cleanup
   in #13342.
2. Run the main-only canary while its current real artifact is still valid. It
   must prove one cold `fill`, one warm `hit`, exact size/digest, and cleanup.
3. Provision or confirm the dedicated `cmux-ci-artifacts` bucket, disable
   `r2.dev`, confirm no enabled custom domain, and set a three-day lifecycle
   for `github/manaflow-ai/cmux/`. Keep the general compilation-cache bucket
   tracked in #13182 unchanged.
4. Configure `GITHUB_ARTIFACT_TOKEN` as the Worker-only repository-scoped
   Actions-read secret and deploy this reviewed Worker, including the
   `ARTIFACT_IMPORTS` and `REQUEST_ADMISSION` Durable Object migrations.
5. Set repository variable `CI_ARTIFACT_R2_URL` to the production
   `https://cmux-ci-artifacts.<account>.workers.dev` origin with no path,
   credentials, query or fragment. Removing that variable returns every
   consumer to the measured GitHub artifact path.

Issue #13364 carries the copy-paste administrator commands, expected output,
live-traffic verification and rollback transcript so privileged operations stay
outside ordinary PR jobs.

## Validation and measurement

`npm run check` typechecks the generated binding types and runs local workerd
tests using real R2/Durable Object implementations with a mocked GitHub origin.
The tests cover all seven immediate consumers coalescing onto one upstream
GitHub transfer, warm hits, corrupt bytes, expiry, wrong producer/workflow,
provider digest mismatch, GitHub API failure, R2 failures and stalls, broker
timeouts, public/private transitions, admission budgets and retry behavior.
Workflow tests execute both real CI consumer contracts with GitHub expressions,
OIDC credential handling and the default-disabled GitHub fallback. Python tests
cover OIDC issuer pinning, secret-file permissions, transfer receipts, bad ZIPs,
wrong producer IDs, stale outputs and traversal/symlink rejection.

`CMUX_TEST_PRODUCT_TRANSFER` records transport, cache result, bytes, broker
first-byte wait and transfer time for R2; the existing GitHub composite records
its end-to-end artifact action duration and payload bytes.
`CMUX_TEST_PRODUCT_RESTORE` separately records the authoritative inner archive
hash/extraction/product-receipt restore duration. Failed broker attempts emit
`CMUX_R2_ARTIFACT_ATTEMPT` with a bounded fallback reason and then use GitHub.
`scripts/ci/measure-r2-artifact-run.py` combines those receipts with Actions
job timestamps to report producer-to-last-consumer wall time and aggregate
producer/consumer runner minutes.

A cold miss necessarily includes one GitHub-to-R2 import before R2 fan-out.
Measure the isolated cold `fill` / warm `hit`, a production R2 run and a
GitHub-fallback run on actual compressed products before treating the lane as
activated. Receipts contain IDs, timings, byte counts and cache outcomes, never
signed URLs or credentials.

References: [R2 streaming writes and checksums](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/),
[GitHub artifact identity and downloads](https://docs.github.com/en/rest/actions/artifacts),
[Durable Objects](https://developers.cloudflare.com/durable-objects/api/base/).

## Isolated deployment canary

The main-only manual `CI artifact transport canary` workflow uses a separately
named Worker, Durable Object namespace and private R2 bucket for each run/attempt. It permits only
artifact `10610975375` and its exact provider digest, requires a random per-run
secret header, and fails closed after a twenty-minute lease or artifact expiry.
The generic broker stays unreachable, and `CI_ARTIFACT_R2_URL` is never changed.

The workflow uses the existing repository Cloudflare account/token. It may create
only `cmux-ci-artifacts-canary-<run-id>-<attempt>` after authenticated lookups
confirm that run's Worker and bucket are absent;
permission failures do not trigger fallback to another account or public bucket.
It verifies public access is disabled and adds a one-day lifecycle for this one
artifact prefix, preserving unrelated rules. Its server GitHub credential is
that job's Actions-read token, never a personal token. Both server secrets are
removed during cleanup along with the run's Worker and exact R2 copy;
a bucket created by that run is deleted only if empty.

Before transferring an artifact, the verifier checks a fixed authenticated
readiness route through the same enabled/expiry/token gate. That route performs
no broker, GitHub or R2 work. Readiness probes have a sixty-second overall bound;
a marked access-gate rejection stops immediately. Safe response-stage markers
separate wrapper rejection from an unmarked endpoint response without recording
credentials, raw headers or response bodies.

One cold fill and one warm read then run on the configured Linux CI runner, with
streamed local SHA-256 verification and separate network/total/hash timings.
Cold failure stops the trial; artifact transfers are never retried. Readiness
attempts are recorded separately and are not counted as artifact performance.
These timings exclude ZIP extraction and cannot be presented as a like-for-like
comparison to the existing complete GitHub download action. The allowlisted
artifact expires on 2026-09-23; an expired artifact requires another reviewed
allowlist change rather than an arbitrary dispatch input.
