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
- Clients send no credentials to the broker. Its server-only token is sent only
  to `api.github.com`, never to redirected blob URLs. No R2 write credentials
  enter PR jobs. The consumer independently obtains the provider ZIP digest
  from GitHub, checks it, and extracts only one bounded, flat product archive.

The default import deadline is 150 seconds (`IMPORT_TIMEOUT_MS`, capped at
150000); R2 metadata/read calls have 10-second response deadlines. The consumer
curl limit is 175 seconds and its subprocess limit is 180 seconds. GitHub
metadata lookup adds up to 20 seconds. Errors, checksum mismatches and invalid
ZIPs leave `hit=false` and use the existing GitHub action. Required inner product
validation is never converted into an optional cache check.

## Enablement

No deployment or live credentials are provided by this change.

1. Provision the private `cmux-ci-artifacts` R2 bucket, with a three-day lifecycle
   for `github/`. Keep the existing public cache bucket unchanged.
2. Provide `GITHUB_ARTIFACT_TOKEN` as a Worker secret: Actions-read access scoped
   to this repository. Set its rotation/expiry ownership and request/rate limits
   on the broker route before enabling CI traffic.
3. The generic configuration has no public routes, `workers_dev=false`, and
   preview URLs disabled. Do not expose it without a reviewed authenticated
   admission policy; otherwise anonymous misses can consume GitHub API quota.
   Run `npm ci`, `npm run check`, then deploy the reviewed Worker normally.
   Wrangler declares the R2 binding and per-artifact Durable Object migration.
4. Only after that production access policy and client integration are reviewed,
   set the repository variable `CI_ARTIFACT_R2_URL` to the HTTPS Worker origin
   with no path, credentials, query string or fragment. Remove the variable to
   revert every consumer to the existing GitHub action.

## Validation and measurement

`npm run check` typechecks the generated binding types and runs local workerd
tests using real R2/Durable Object implementations with a mocked GitHub origin.
The tests cover six concurrent consumers and one upstream transfer, active CI
with successful compile, checksum rejection with no committed object, failed or
wrong producers, public/private transitions, and bounded concurrent waits.
Workflow tests execute both real CI download steps with GitHub expressions and
local command fixtures, including the default-disabled path. Python tests cover
bad ZIPs, wrong producer IDs, stale outputs and traversal/symlink rejection.

A cold miss adds a GitHub-to-R2 import before the R2 fan-out; it is not claimed
to be faster. Measure end-to-end producer-to-last-consumer time, per-consumer
download time, aggregate allocated runner time, hit/fill/miss counts and fallback
delay on actual compressed products before widening usage. Log records contain
artifact ID, byte count and cache outcome, not signed URLs or credentials.

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
