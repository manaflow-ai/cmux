# CMUX workload profiles

CMUX workload profiles give CI, developers, Glaeda, machine acceptance, and fleet measurements one repository-owned name for the operations CMUX repeatedly asks a machine to perform.

The profile registry lives at `scripts/ci/cmux-workload-profiles.json`. `scripts/ci/cmux_workload_profile.py` validates, plans, runs, and compares those profiles. Each profile delegates to checked-in CMUX entrypoints; the runner is a semantic dispatcher and receipt producer.

## Identity

A request freezes three independent identities:

- source: `manaflow-ai/cmux` plus exact commit and tree;
- semantic operation: profile ID/generation plus its reviewed environment class;
- physical execution: backend, machine, attempt, cache placement, and other executor facts.

The runner does not inherit the caller's arbitrary environment. Each profile executes with a closed
environment class, task-private HOME/TMPDIR/config/Rust state, a reviewed PATH, exact profile/source
identity, semantic parameters, and only declared runtime-input variables. SSH agents, arbitrary
tokens, caller PATH entries, and unrelated CI variables never flow into the profile child.

Profiles in the `isolated-build` environment class hold one nonblocking checkout mutation lease for
the full child lifetime so repository-level generated build inputs cannot be replaced by a second
participating build profile. After the child settles, the runner revalidates the frozen source and
rehashes every declared runtime input before it can publish a result. Source or input drift refuses
the run instead of minting a receipt for mixed bytes.

Profile generation is deliberate semantic versioning. Refactoring a wrapper, moving an internal helper, or changing an implementation detail can preserve the generation when the accepted source, validation, and expected result remain equivalent. Change the generation when the operation, selected tests, validity criteria, expected artifact/result class, or other pass/fail semantics change.

The exact source commit/tree still records which implementation ran.

## First generation

| Profile | Generation | Repository entrypoint | Meaning |
| --- | ---: | --- | --- |
| `cmux.macos.compile-admission` | 1 | `scripts/ci/workloads/macos-compile-admission.sh` | Resolve dependencies, use the canonical app-host compile script, compile the app-host test products, and validate the warning budget. |
| `cmux.macos.dev-check` | 1 | `scripts/ci/workloads/macos-dev-check.sh` | Run the canonical tagged `reload.sh` build with a profile-owned unique tag, private DerivedData/SourcePackages, no launch, no global CLI links, local backend mode, and cloud dogfood disabled. |
| `cmux.macos.app-host-test-shard` | 1 | `scripts/ci/workloads/macos-app-host-test-shard.sh` | Run one of six physical app-host shards as the same two deterministic logical selector batches used by CI, against an exact xctestrun input. |
| `cmux.ci.guard` | 1 | `scripts/ci/workloads/ci-guard.sh` | Run the portable CI routing, runner-policy, required-check, shard-definition, and test-wiring guard set. |

This is intentionally a small set. Tiny workflow steps stay ordinary workflow steps until they have useful machine-acceptance, routing, cache, or performance meaning.

## Running a profile

Inspect the current registry:

```sh
python3 scripts/ci/cmux_workload_profile.py list
python3 scripts/ci/cmux_workload_profile.py describe cmux.ci.guard
```

Plan against the current exact checkout:

```sh
python3 scripts/ci/cmux_workload_profile.py plan cmux.ci.guard \
  --generation 1 \
  --state-class cold
```

Run it and publish a canonical semantic result:

```sh
state_root="$(mktemp -d)"
result_path="$state_root/result.json"
python3 scripts/ci/cmux_workload_profile.py run cmux.ci.guard \
  --generation 1 \
  --state-class cold \
  --state-root "$state_root" \
  --result "$result_path"
```

An external execution request should also pass the frozen `--commit` and `--tree`. The runner refuses source drift and generation drift. Keeping a file result under the profile state root is the preferred path and gives downstream consumers mode-`0600` canonical bytes. The publisher also supports trusted root-owned sticky temporary directories such as `/tmp` through the same descriptor-relative exclusive staging and atomic replacement path.

`cmux.macos.app-host-test-shard` has one semantic parameter:

```sh
CMUX_APP_HOST_XCTESTRUN=/absolute/path/to/exact.xctestrun \
python3 scripts/ci/cmux_workload_profile.py run cmux.macos.app-host-test-shard \
  --generation 1 \
  --state-class exact-product-reuse \
  --state-root /absolute/private/state \
  --param shard=3
```

The xctestrun path is a runtime binding. Its content digest enters the comparison identity; the path itself does not.


For macOS profiles, Xcode selection is local to the workload environment. The profile runner sets
`CMUX_CI_SKIP_XCODE_SELECT=1`, so `scripts/select-ci-xcode.sh` exports the selected
`DEVELOPER_DIR` without changing the machine-wide `xcode-select` default. The exact selected
toolchain is then re-observed through the profile's private environment and included in the result
context.

## Result contract

Every completed run emits `cmux-workload-result/v1` with:

- exact repository, commit, and tree;
- profile ID and generation;
- CMUX semantic validator identity and reviewed environment class;
- `passed`, `failed`, `timed_out`, or `ambiguous`;
- runtime input and output artifact identities;
- named stage timings;
- bounded CPU/RAM and toolchain observations;
- benchmark state class and comparison keys;
- cleanup/process-settlement state.

CMUX owns this semantic result. Glaeda and other executors can wrap it with queue time, machine identity, placement evidence, resource accounting, transfer time, cache placement, lease/attempt identity, and physical cleanup evidence.

A leaked child process makes the semantic result ambiguous even when the entrypoint exited zero.

## Controlled benchmark state

The registry admits only state classes the profile can use meaningfully:

- `cold`: empty runner-owned state;
- `dependency-warm`: dependency material may already exist;
- `compiler-warm`: dependency and compiler-cache material may already exist;
- `exact-product-reuse`: the exact validated product is supplied as a runtime input;
- `resident-hot`: the reviewed resident profile state is retained.

A cold run uses an empty state root. If `--state-root` is omitted, the runner creates a temporary one; if a root is provided explicitly, it must already be empty. Warm classes require an explicit state root so cache state is intentional.

The result contains two comparison identities:

- `semantic_comparison_key`: exact source tree, profile ID/generation, validator, environment class, semantic parameters, and runtime-input content identities;
- `comparison_context_key`: semantic key plus benchmark state class and toolchain identity.

`compare` rejects results when either key differs, either semantic result failed, required artifact validation is incomplete, or cleanup was incomplete:

```sh
python3 scripts/ci/cmux_workload_profile.py compare left.json right.json
```

Backend and hardware class stay outside that key so the same valid operation can compare GitHub-hosted, CMUX-owned, and Glaeda-dispatched machines while preserving source, tests, validator, cache class, and toolchain equivalence.

## Machine roles

The first role mapping is:

```yaml
cmux_linux_ci:
  acceptance:
    profile: cmux.ci.guard
    generation: 1

cmux_macos_native_build:
  acceptance:
    profile: cmux.macos.dev-check
    generation: 1
```

`cmux.macos.compile-admission` is the acceptance target for a future compile-admission role used by persistent CI Macs. `cmux.macos.app-host-test-shard` can back `cmux_macos_test` after the role has an exact product-delivery contract.

A node may claim a role only after the current exact acceptance profile succeeds for that role and current enrollment/toolchain generations.

## Glaeda boundary

A Glaeda request for CMUX work should carry semantic identity only:

```json
{
  "source": {
    "repository": "manaflow-ai/cmux",
    "commit": "<40-hex>",
    "tree": "<40-hex>"
  },
  "profile": {
    "id": "cmux.ci.guard",
    "generation": 1
  }
}
```

Glaeda may choose an eligible backend, allocate resources, restore admitted cache state, and execute the checked-in profile runner from the exact source tree. It should never reconstruct the profile's shell/Xcode command or maintain its own definition of CMUX pass/fail semantics.

## Benchmark corpus

The profile vocabulary and benchmark fixture corpus are separate. The first fixture generation should cover:

- a small source-only edit;
- a package/project-graph edit;
- a settings/config edit;
- an app-host/UI-test edit;
- a web-only edit;
- a CI-only edit;
- a Release-producing edit.

Prefer checked-in generated fixtures where an old production revision would become stale. Each fixture should freeze its generator/version and expected affected profile set. Exact historical revisions are appropriate only when the source itself is the behavior under study.

Performance aggregation belongs outside a single semantic result. Store p50/p90 with profile ID/generation, fixture, state class, CPU/RAM class, toolchain, cache/product reuse, and backend.
