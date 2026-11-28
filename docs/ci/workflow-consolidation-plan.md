# Workflow consolidation: pinned inventory and delivery plan

Leo: "where's the ci unification and simplification and speedups?"

The current plan is **316 → 119 workflow files** at `manaflow-ai/cmux@230b66b08dd88ab66fea47a6827b26d92d593e5e`. The 119 is a proposed end-state budget, not an implemented result or proof that every merger is safe. No inactive workflow is declared dead solely from an empty or capped run sample. This is the action plan for the revised stop condition: consolidation plan plus first PRs; retention documentation alone does not complete it.

The companion `workflow-consolidation-inventory.json` assigns all 316 paths to exactly one purpose area. The earlier 304/311 counts describe different snapshots. A `repo_files` call at this same SHA returns only 315 because it hides `classic-frozen-guard.yml`; `repo_tree` returns all 316. Count `.yml` and `.yaml`, including frozen paths. The measurement receipt is `repo_tree(repo="cmux", ref="230b66b08dd88ab66fea47a6827b26d92d593e5e", path=".github/workflows")`.

## Area budgets

| Area | Snapshot files | Proposed files | Owner / migration lane |
| --- | ---: | ---: | --- |
| delivery-protected | 70 | 70 | release/nightly owners; no edits in this lane |
| classic-frozen | 1 | 1 | frozen classic owner |
| app-platform | 25 | 7 | app/platform helper |
| cloud-backend | 35 | 8 | backend/cloud helper |
| performance-gallery-docs | 15 | 7 | hygiene/bench helper |
| storage | 5 | 1 | storage helper |
| pr-routing-guards | 29 | 6 | PR/guards helper |
| next-build-batch | 24 | 4 | NEXT build/batch helper (assign owner) |
| web-validation | 9 | 2 | web helper |
| rust-build-cache | 24 | 4 | Rust/build owner (coordinate build-once-test-many) |
| service-validation | 11 | 1 | cloud/services helper (assign owner) |
| journeys-reliability | 33 | 3 | journey/reliability helper (assign owner) |
| ci-maintenance | 24 | 3 | maintenance/guards helper |
| infrastructure-operations | 11 | 2 | operations helper (assign owner) |
| **Total** | **316** | **119** | **197 fewer files; design target, not landed** |

The 70 delivery files include release, nightly, promote, dev, package publication, their static reusable closure, and protected deployment entrypoints from the cloud lane. They remain byte-identical. The frozen classic guard adds one unchanged file. This leaves 245 candidate files with a proposed budget of 48. The target has only one file of headroom below 120: an additional protected or externally called entrypoint requires finding another proven consolidation, not deleting coverage to preserve the number.

Original helper drafts were app/platform 27→9, cloud/backend 49→19, benchmark/support 17→10, and storage 5→1. Those are **not additive**: fleet-compile/test/RD-host occur in app and cloud, measure-swift-typecheck occurs in app and benchmark, and docs-deploy-reusable occurs in cloud and benchmark. This plan assigns delivery protection first, then app, cloud, benchmark and storage, so each path is counted once. The revised smaller area budgets below are candidate architecture designs, not a claim those helpers already implemented them.

## Concrete migrations

### app-platform: 25 → 7

Native checks, iOS validation, fleet manual build gateways, platform build and cache seed dispatchers; protected iOS entrypoints stay in delivery group. Delete fleet-test-compile only with exact caller/coverage proof.

### cloud-backend: 35 → 8

Separate dispatchers for backend checks, chief, cloud journeys, app proofs, operations, VM static checks, fleet operations and mobile deployments. Keep credentials/job permissions distinct; image-graduate moves into operations only after promotion caller audit.

### performance-gallery-docs: 15 → 7

One manual performance selector, one gallery selector; retain performance scheduler, docs fallback and distinct protected/runtime report contracts. Combine report entrypoints only with event/job equivalence proof.

### storage: 5 → 1

One storage-maintenance dispatcher; paired main/NEXT changes preserve cron task selection and per-job credentials. 5→1 has concrete implementation and offline routing proof.

### pr-routing-guards: 29 → 6

Retain classic entrypoint, NEXT router, step pipeline, PR advisory dispatcher, merge-queue policy entrypoint, and guard reusable. Move check bodies into ci/steps.toml or selected guard jobs while preserving status context names and read-only/base-code trust boundaries. Swift 2→1 is first cut.

### next-build-batch: 24 → 4

Keep platform build reusable, compile gateway, post-merge batch orchestrator and verification dispatcher. Move platform variants into selected jobs/matrices; existing three batch wrappers become one platform selector. Required checks, caller permissions and delivery references are migration blockers until tested.

### web-validation: 9 → 2

One web build reusable and one web validation dispatcher; migrate lint/complexity/asset checks into selected pipeline steps. Publish remains protected.

### rust-build-cache: 24 → 4

Build reusable, platform packaging dispatcher, Rust verification dispatcher, cache/diagnostic dispatcher. Keep protected reusable build-package unchanged. Audit channel and signing dynamic callers first; no duplicated build jobs removed without artifact equivalence proof.

### service-validation: 11 → 1

One service workflow with workflow_call and explicit dispatch selectors, separate service jobs, environments and event filters. No blanket permission union; do not migrate any production caller without owner review.

### journeys-reliability: 33 → 3

Separate Linux/service journey, native/UI journey and evaluation dispatchers. Preserve suite identities, per-suite routing, runner labels, artifacts and concurrency. Nightly consumers require compatibility names until migrated; budget is conditional on that audit.

### ci-maintenance: 24 → 3

Separate PR lifecycle cleanup, CI health/repair, and generated/base repair dispatchers. Preserve cancellation-group semantics: merging skipped closed-PR workflows is unsafe without equivalent cancellation of all original groups. #61914 is first proven 2→1 shape.

### infrastructure-operations: 11 → 2

One read-only diagnostics and one explicitly selected maintenance dispatcher; preserve job-level environments, credentials and destructive-input defaults. Signing-keychain is protected on any delivery reachability finding.

## First PRs and the parallel sequence

- PR/guards lane: [#61914](https://github.com/manaflow-ai/cmux/pull/61914), `322777aff39c2f1ec31fee2284bb115e94706544`, combines PR cleanup entrypoints, pinned branch count 315→314. It is open, not merged in this plan's evidence. Targeted cleanup units passed; broader audit attribution and exact-head review/landing remain its owner's work.
- PR/guards lane: Swift reusable consolidation at `4645726bf3e6bec0b045b2f245aaf77a22890451`, based on `0d5f50bedc2439ea335e9be71a5e0a4c7db3af46`, pinned count 315→314. Retains registered `swift-acpmux-protocol.yml`; ratchet caller selects `check: ratchet`, post-merge selects `check: acpmux`. Opened as [#61885](https://github.com/manaflow-ai/cmux/pull/61885); exact-head code review is SHIP, CI/landing is pending. This plan supplies no merge claim.
- App/platform + PR/guards: retire superseded `fleet-test-compile.yml` only after retaining planner tests and post-merge coverage, and migrating metadata. One deletion belongs to one lane and must not be counted twice.
- Cloud lane: combine the first two compatible manual probes, area 2→1. Land only after exact dispatch and registration migration. The larger 35→8 budget is the subsequent dispatcher work, not this first patch.
- Benchmark lane: merge manual web-performance/stress dispatchers, area 2→1, preserving selected suite and concurrency behavior. Remaining benchmark/gallery/report grouping follows separately.
- Storage lane: five active maintenance wrappers → one dispatcher, with main-first then paired NEXT PR because schedules execute default-branch definitions. Preserve seven runnable jobs, four schedules and all destructive-input semantics. Offline route/payload proofs exist in the helper; pin and attach them to the actual PR head before landing.

Run these areas concurrently through `tools/lane split`; do not start duplicate lanes over existing helper files. PR/guards integration owns the Swift/cleanup overlap; root assigns the named new NEXT-build, Rust, journey and infrastructure lanes. Each lane first lands a small independently valid cut, then expands its dispatcher until its area's budget is met or a specific caller/permission constraint requires reallocating the budget. The JSON is the ownership partition; update it and the plan in the same PR when scope moves.

## What each cut must prove

1. Read all `workflow_call`, `workflow_dispatch`, script/CLI and cross-repository callers; inspect required-check references read-only. No GitHub setting/ruleset change. Keep a compatibility entrypoint if a protected delivery path still depends on its filename. Static reusable edges are only the initial closure: dynamic dispatch discovery can enlarge it.
2. Preserve per-suite events/path filters, default inputs, environments, least-privilege job permissions, runners, timeouts, artifacts and required status names. Select jobs directly from the event/input where possible, so consolidation adds no runner just to route work. Do not convert several distinct cancellation groups to one group that evicts siblings or protected runs.
3. For a dead-file deletion, attach a complete per-workflow 30-day run census ending at a recorded UTC time, plus caller/required-check proof. A missing feed row means unknown. A superseded leaf can instead be removed with exact replacement coverage proof. A zero-run scheduled workflow needs diagnosis before treating it as dead.
4. Update router tables, job-input/same-tree-reuse/post-merge metadata, tests and operational dispatch references atomically with each move. Retain registered filenames for dispatch compatibility or prove the replacement registers from the correct branch. Scheduled migrations need main twins.
5. Dry-run both old and new event/dispatch matrices, including invalid inputs, closed/synchronize/edited PRs, forks, main versus NEXT, cron selectors and simultaneous suites. Compare old/new selected job sets. For nightly/release/promote, recompute the caller closure, show unchanged protected bytes, and run the repository's offline nightly dry run at the exact candidate head. A static graph is not a real published nightly receipt; do not claim live publication was exercised.
6. Review and run scoped CI on the exact final head, attribute any base failure with receipts, then use pinned land-judge on green. Do not cancel nightly, dev or promote runs, use admin bypass, or build on cosmic-gray/Air Blue. Send the lead/coordinator one line per merge with repository, SHA, count delta and measured cost. Add the requested commit coauthor and PR footer.

## Runner minutes/day: measured versus unknown

The full repository's before and after runner-minutes/day are **unknown** until a complete duration feed is joined by workflow/job, source SHA, trigger and time window. The first file-only cuts preserve runnable bodies; claimed scheduled savings are **0 runner minutes/day**. Manual runtime savings are unmeasured, not zero by assumption. Do not multiply deleted files by an assumed average duration or credit historical trigger cuts again.

For the active storage tasks, intended scheduled jobs/day remain `24 + 1 + 1 + 4/7 = 26.5714`; consolidating the coincident Monday entrypoints reduces workflow invocations by `1/7` per day and saves **0 runner minutes/day**. This is orchestration simplification only.

The census lane must attach raw source and completeness watermark, sum `completed_at - started_at` across actually executed runner jobs (deduplicate job IDs; include retries explicitly), divide minutes by observed days, and report before/after matched windows and matched event volume. Queue time, skipped jobs and workflow record counts are not runner time. Record aggregate runner minutes and, if available, measured CPU time separately. Speedups require additional duplicate-job removal, shared build artifacts or routed execution, coordinated with the build-once/test-many owner; file consolidation alone does not establish them.

## Exit and reporting

A plan plus open first PRs meets the newly requested planning milestone only when their links/heads are recorded. PR owner work ends at merged receipts. The actual fewer-than-120 end state is not achieved here. Keep `implemented_after` null until a measured merged snapshot exists; every merge records its own base→head delta without summing moving repository totals. Expand or revise the proposed budgets when migration proof disproves a candidate rather than labeling retained paths as completion.
