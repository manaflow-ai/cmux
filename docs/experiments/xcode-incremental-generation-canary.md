# Xcode incremental generation canary

This note records the experiment and the acceptance contract for carrying a worktree generation together with Xcode DerivedData across disposable macOS runners. It is benchmark material only; it does not route required CI.

## Hypothesis

Xcode's incremental build database remains useful across disposable runners when the previous source worktree is restored with its file mtimes intact, then Git advances that existing worktree to the next candidate revision. Unchanged source files keep the signatures Xcode recorded in the previous build, while changed files receive new mtimes/content through the Git transition.

The shared Xcode compilation CAS is separate. CAS hit/miss counts are reported separately and are never used as evidence of incremental-build reuse.

## Why the older DerivedData restore failed

The old cloud path had two independent problems. Some reload jobs never restored a reusable entry because per-dispatch keys, ref scoping, and cache eviction caused misses. When DerivedData was restored against an ordinary fresh checkout, actions/checkout gave tracked source files fresh mtimes newer than compiler outputs, so Xcode treated the restored incremental database as stale.

reload-build.yml later added deterministic per-blob mtimes, and a same-commit Xcode 26.6 experiment then rebuilt with two Swift compiles. The canary deliberately compares fresh-checkout timestamps against a restored worktree generation across an actual source change.

## Controlled source pair

A = 2393fd16b875819909c8f633271934a3f6d0292e.
B = 2f943925239bcff183fcb452379725fa3b4b4b20.

B is A plus a comment-only edit in Sources/Mobile/MobileTerminalByteTee.swift. This keeps the first experiment focused on one app-target Swift source edit without a public-interface, package, project-file, or test-target change.

## Arms

All arms use the canonical scripts/ci/compile-app-host-test-product.sh, the same runner class, selected Xcode/SDK, Swift package policy, and shared compilation CAS policy.

1. Cold fresh checkout B + empty DerivedData.
2. Fresh checkout B + DerivedData built at A.
3. Restored worktree A + restored DerivedData A, then in-place checkout to B.
4. Same as 3, but advance through a synthetic PR merge commit.
5. Same as 3 with the restored worktree at a different absolute path.
6. Same as 3 with DerivedData at a different absolute path.

The relocation arms quantify path dependence instead of inferring it from a failure.

## Metrics

Each row records build wall time; SwiftCompile task count; Xcode Build Timing Summary time for SwiftCompile and SwiftEmitModule; compilation-CAS hit and miss mentions separately from incremental tasks; worktree and DerivedData disk bytes; compressed archive bytes; compression, upload, download, and extraction time; exact paths; source mtime/device/inode diagnostics; and Xcode/SDK identity.

## Decision matrix

Interpret the changed-source arms in this order:

- Restored worktree + DD fails to reduce incremental tasks: reject the hypothesis.
- Restored worktree wins, and fresh checkout + blob-normalized mtimes matches its
  task count and wall time: prefer the normalized DD-only path. It removes the
  source archive and its transfer/security surface.
- Restored worktree wins materially over normalized mtimes: retain the worktree
  generation and treat the difference as evidence that Xcode needs additional
  source identity/state beyond per-blob mtime.
- Either warm arm wins build wall but loses after download/extract plus previous
  generation compression/upload: stop before production CI and reduce the DD
  state set/transport cost first.
- A relocation arm that loses while the fixed-path arm wins makes absolute path
  part of generation identity; it is a compatibility miss, not a recoverable
  warm hit.

## Break-even

For a revision after the seed, define F as fresh-checkout build wall time, W as restored-generation build wall time, D as generation download plus extraction, P as compression plus upload charged to the previous successful revision, and S as source-generation restore/transition overhead.

A steady-state generation chain improves total CI work when F - W > D + S + P.

If publication can occur outside the authoritative required-check critical path, report both feedback latency and total macOS/transfer consumption. A generation that wins compile time but loses after transfer stops here.

## Transport choice for a first PR pilot

Use a one-day GitHub Actions artifact for the first generation pilot.

The existing private R2 compiled-product broker is optimized for one immutable
GitHub artifact feeding several consumers. It still requires the producer to
upload the GitHub artifact first, and a cold broker miss adds a GitHub-to-R2
import before the consumer read. A generation chain normally has one consumer:
the next run of the same PR. Extending broker admission to fork-produced mutable
build state therefore adds policy and another transfer leg before it proves a
latency win.

The GitHub dependency cache is also a later option, not the first pilot. Same-PR
ref scoping is useful isolation, but #13160 removed PR cache writes after
multi-gigabyte entries evicted trusted seeds under the repository's then-active
cache budget. Reintroduce that backend only with an explicit storage/eviction
decision and measurements. The canary should keep generation state out of the
shared compilation-CAS namespace.

## Identity contract for any later canary implementation

Reuse scripts/ci/product_input_identity.py for app-host identity, but compare its fields deliberately: the algorithm and recipe fingerprints must match while the seed and candidate source fingerprints are recorded separately and are expected to differ for the changed-source use case. A generation manifest additionally binds repository, PR number, head repository, producer PR head SHA, seed commit/tree, exact candidate commit/tree at consumption, Xcode and selected developer directory, macOS SDK version/build, architecture/runner class, absolute workspace path, absolute DerivedData path, Package.resolved digest, recursive submodule identity, generation schema, archive digests, and byte/file ceilings.

The producer PR head SHA must be an ancestor of or equal to the current PR head SHA. A force push onto unrelated history is therefore a compatibility miss. The synthetic merge source SHA itself may differ and need not be an ancestor of the next synthetic merge, because the base branch can advance between PR runs; record the exact seed merge tree and exact candidate merge tree independently. The seed commit may differ from the candidate commit. Unknown identity fields fail closed to a cold compile.

## Untrusted-state threat model

Mutable incremental generations never cross PR boundaries. Fork or otherwise untrusted generations are scoped to one PR lineage, execute only on disposable macOS runners with no repository secrets, and are never restored on persistent trusted fleet hosts.

Treat the archive as attacker-controlled input. Extract into empty staging with rejection of path traversal, absolute paths, hardlinks, device nodes, and escaping symlinks. Verify archive digests and bounded byte/file counts before adoption. Re-bind source to an exact Git commit/tree and require a clean tree. Toolchain, paths, package lock, submodules, and recipe identity must match. Any corruption, mismatch, interrupted publication, or failed validation deletes staged state and falls back to the normal clean compile.

PR code may corrupt only its own disposable generation. It gains no authority over a later unrelated PR or a trusted machine.

## Authoritative validation

Generation reuse is acceleration. It does not reuse test success. The merge queue can retain a clean compile as the authoritative gate.

For fork/contributor generations, same-run app-host products may feed that PR's own test shards, but they must never enter the cross-run compiled-product reuse pool. The existing merge-group product selector accepts exact products from eligible PR producers; a generation-backed untrusted producer therefore needs an explicit non-reusable provenance bit (or must omit the reusable-product seal) so merge-group lookup rejects it and performs a clean compile. The clean merge-group compile may still read the trusted main-seeded compilation CAS.

## Canary implementation boundary

If the changed-source restored-generation arm wins after transfer cost, the smallest next step is an off-by-default PR-only canary selected by a repository variable/workflow input, limited to explicit cohorts and same-PR previous-generation consumption. Missing or invalid state falls back immediately to the current hosted compile and every attempt uploads raw metrics.

If the benchmark loses after transfer, stop at the evidence and investigate smaller state sets or deterministic mtime normalization instead.

If the benchmark clears that gate, the repo integration stays narrow:

- `CI_INCREMENTAL_GENERATION` is unset/off by default; a pilot value and optional
  cohort list select explicit PRs.
- Only `pull_request` consumers participate. `merge_group` always takes the
  clean path.
- Discovery happens only after exact compiled-product reuse misses and before
  package readiness/compile. The persistent-Mac product path remains independent.
- Provenance/artifact handling should reuse or factor the bounded GitHub API,
  digest, attempt, same-PR pairing, and extraction code already in
  `reuse_app_host_products.py`.
- Generation selection differs from compiled-product selection in one important
  way: source revisions are expected to differ. Recipe/toolchain/path/package
  identities must match, while the manifest records both exact seed and exact
  candidate trees.
- Fork producers are eligible only for the next disposable run of the same PR.
  Their generation provenance never satisfies cross-run compiled-product reuse.
- Restore failure, identity mismatch, corrupt archive, unavailable producer, or
  API failure records a reason, deletes staging, and continues through the
  current clean hosted compile.
- A successful compile may publish the next immutable generation with one-day
  retention. Publication failure does not fail the authoritative compile.
- Extend the existing compile-admission metrics with generation lookup,
  download, validation/extraction, source transition, publish seconds/bytes,
  incremental task counts, emit-module time, and CAS counts.



## Measured evidence so far

### Existing hosted admission baseline

PR #13432 commit d28027e ran hosted compile admission in workflow run 35645230722.
The R2 compilation CAS restored by prefix in 23.748 seconds. The subsequent
compile still took 990.199 seconds. The log contained 1,124 compiler-CAS hit
mentions and 2,682 miss mentions overall; target cmux accounted for 47 hits and
2,638 misses.

A later #13432 head run compiled in 821.282 seconds and still recorded 2,639
cmux-target CAS misses. This is motivation only; the canary uses its own matched
A/B runner measurements for acceptance.

### Natural-mtime canary run 35671427595

The first canary accidentally omitted CI_CACHE_R2_PUBLIC_URL, so the R2 restore
action correctly reported the store as unavailable. Treat its build rows as a
CAS-cold experiment, not as the production-CAS comparison. The corrected
canary adds the endpoint before another run.

Completed producer A measurements:

- cold build wall: 796.096 seconds;
- SwiftCompile log lines: 10,307;
- CAS hit/miss mentions: 0 / 3,708;
- DerivedData disk: 7,524,298,752 bytes;
- worktree disk: 2,056,282,112 bytes;
- DerivedData archive: 2,087,797,886 bytes;
- worktree archive: 167,339,616 bytes;
- total generation archive: 2,255,137,502 bytes;
- DerivedData compression: 56.242 seconds;
- worktree compression: 5.393 seconds;
- DerivedData artifact upload: 17.429 seconds;
- worktree artifact upload: 3.378 seconds;
- producer compression + upload overhead: about 82.44 seconds.

The matched cold-fresh B arm took 946.270 seconds and produced 10,307
SwiftCompile log lines with 0 / 3,708 compiler-CAS hit/miss mentions.

The fresh-checkout + restored-DerivedData B arm took 912.263 seconds and
produced the same 10,307 SwiftCompile lines with 0 / 3,708 CAS hit/miss
mentions. Its 2.088 GB DD artifact took 120.599 seconds to download and
19.315 seconds to extract. Against the 82.442 seconds of seed compression +
upload, the steady-state accounting for this arm is about 1,134.619 seconds
versus 946.270 seconds cold: 34.008 seconds of build-wall saving is overwhelmed
by about 222.356 seconds of generation transport/preparation. This arm therefore
reproduces the old failure mode: a fresh checkout discarded useful incremental
state.

The restored-worktree arm in this first run failed before Xcode because the
prototype source archive included two submodule directories without their Git
metadata. That is a harness failure, not a hypothesis result. The corrected
archive excludes every submodule worktree and rehydrates submodules normally.

The build-timing fields in this first run are intentionally excluded: a harness
PATH bug prevented the timing wrapper from reaching xcodebuild. The build
invocation itself remained the canonical compile script. The corrected harness
has a green Linux regression test for the fixed wrapper/parser path and uploads
the raw cmux build log for recomputation.


### Corrected production-CAS canary run 35676212414

The corrected canary exports the same R2 public endpoint used by compile admission.
The seed's compilation CAS restored by prefix in 26.296 seconds from
`xcode-compilation-test-macOS-ARM64-c4728a44cf18adc521070ca61d009904-9e4b77c...`.
The action's `cache-hit=false` means only that the exact key missed; the
matched-prefix restore succeeded and the compiler log confirms reuse.

Producer A:

- build wall: 964.005 seconds;
- SwiftCompile source-file log lines: 10,307;
- Xcode SwiftCompile timing: 3,152.710 aggregate task-seconds across 3,138 tasks;
- SwiftEmitModule timing: 30.222 aggregate task-seconds across 91 tasks;
- compiler-CAS hits/misses: 832 / 2,876;
- target `cmux` CAS hits/misses: 45 / 2,641;
- full DerivedData disk: 7,460,159,488 bytes;
- retained incremental subset disk: 7,222,398,976 bytes;
- retained DD archive: 2,017,450,863 bytes;
- worktree archive: 160,254,248 bytes;
- total generation archive: 2,177,705,111 bytes;
- DD + worktree compression: 59.444 seconds;
- DD + worktree artifact upload: 13.254 seconds;
- producer publication overhead from compression + upload: 72.698 seconds.

Matched cold-fresh B:

- build wall: 998.314 seconds;
- SwiftCompile source-file log lines: 10,307;
- Xcode SwiftCompile timing: 3,185.522 aggregate task-seconds across 3,138 tasks;
- SwiftEmitModule timing: 30.055 aggregate task-seconds across 91 tasks;
- compiler-CAS hits/misses: 832 / 2,876;
- target `cmux` CAS hits/misses: 45 / 2,641.

These rows establish the corrected cold baseline and confirm that compiler CAS
behavior is comparable across A/B. They do not yet establish incremental reuse;
that decision comes from the restored-generation and normalized-mtime arms.

The earlier run also exposed material artifact-transfer variance for the 2.088 GB
DD archive: 29.6, 35.8, 120.6, 141.3, and 1,463.2 seconds across five downloads.
The 1,463-second tail is a real observed transfer result and would erase any
incremental-build win on that attempt. Keep raw transfer rows in the acceptance
decision instead of comparing build wall alone.


## Synthetic seed rebind feasibility

A local Git fixture tested a case where the real seed commit object was absent
from the restored repository. The producer recorded the seed index entries
(mode, blob/commit object id, path) and archived the working files without
.git. The consumer fetched only B, loaded the recorded entries with
git update-index --index-info, wrote a tree with git write-tree --missing-ok,
created a local synthetic seed commit, refreshed the index against the restored
files, and checked out B.

The pre-transition tree was clean, the unchanged source retained its mtime, the
edited source changed to B, and the real A commit remained absent. This is a
practical way to consume a generation built from an older synthetic PR merge
even if GitHub no longer advertises that exact merge commit. It also avoids
putting the repository object database into the generation artifact.
