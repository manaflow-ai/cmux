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

## Break-even

For a revision after the seed, define F as fresh-checkout build wall time, W as restored-generation build wall time, D as generation download plus extraction, P as compression plus upload charged to the previous successful revision, and S as source-generation restore/transition overhead.

A steady-state generation chain improves total CI work when F - W > D + S + P.

If publication can occur outside the authoritative required-check critical path, report both feedback latency and total macOS/transfer consumption. A generation that wins compile time but loses after transfer stops here.

## Identity contract for any later canary implementation

Reuse scripts/ci/product_input_identity.py for app-host source and recipe identity. A generation manifest additionally binds repository, PR number and head repository, seed commit/tree, exact candidate commit/tree at consumption, Xcode and selected developer directory, macOS SDK version/build, architecture/runner class, absolute workspace path, absolute DerivedData path, Package.resolved digest, recursive submodule identity, generation schema, archive digests, and byte/file ceilings.

The seed commit may differ from the candidate commit. Unknown identity fields fail closed to a cold compile.

## Untrusted-state threat model

Mutable incremental generations never cross PR boundaries. Fork or otherwise untrusted generations are scoped to one PR lineage, execute only on disposable macOS runners with no repository secrets, and are never restored on persistent trusted fleet hosts.

Treat the archive as attacker-controlled input. Extract into empty staging with rejection of path traversal, absolute paths, hardlinks, device nodes, and escaping symlinks. Verify archive digests and bounded byte/file counts before adoption. Re-bind source to an exact Git commit/tree and require a clean tree. Toolchain, paths, package lock, submodules, and recipe identity must match. Any corruption, mismatch, interrupted publication, or failed validation deletes staged state and falls back to the normal clean compile.

PR code may corrupt only its own disposable generation. It gains no authority over a later unrelated PR or a trusted machine.

## Authoritative validation

Generation reuse is acceleration. It does not reuse test success. The merge queue can retain the current clean compile as the authoritative gate.

## Canary implementation boundary

If the changed-source restored-generation arm wins after transfer cost, the smallest next step is an off-by-default PR-only canary selected by a repository variable/workflow input, limited to explicit cohorts and same-PR previous-generation consumption. Missing or invalid state falls back immediately to the current hosted compile and every attempt uploads raw metrics.

If the benchmark loses after transfer, stop at the evidence and investigate smaller state sets or deterministic mtime normalization instead.
