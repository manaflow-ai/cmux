# Machine router: invisible cloud machines for coding agents

Status: v1 shipped in the CLI (`cmux vm run`); this doc records the design and
the path to the control-plane version that pairs with the CodeRouter model
plane.

The router is a policy primitive used by the Rust Cloud client. Its work-key,
pool, health, lease, and failover rules must return the stable machine,
operation, and verification records defined in
[the Cloud Rust system design](../cloud-rust-system-design.md). The existing
Swift vm run path is a compatibility caller, not a second routing policy.
Implementation order and acceptance gates are in
[the Rust Cloud CLI plan](../../plans/feat-cloud-rust-cli/DESIGN.md).

## Goal

An agent (Claude Code, Codex, or any open-source-model harness) should be able
to say *"run this in the cloud"* and never think about machines: no ids, no
capacity, no setup. The router picks the computer, provisions when needed,
keeps warm state where the work is, and meters usage. The model plane hides
credentials behind a VM-local endpoint bound to machine identity.

## v1: CLI-side router (this repo, shipped)

`cmux vm run [--sync] [--pull <remote>] -- <command...>` routes over the existing `vm.*` socket methods:

1. **Sticky first.** A local binding store (`~/.cmuxterm/vm-run-bindings.json`) maps a work key (the SHA-256 hash of the caller's directory) to the machine that last ran that work. A bound, ready pool machine wins outright because it holds the synced checkout, installed dependencies, and build caches. This mirrors coderouter's sticky `conversationKey → credential` assignment, which exists for the same reason (warm state is throughput).
2. **Then load-aware scoring.** Pool machines (persisted pool id list (`~/.cmuxterm/vm-run-pool.json`; the `agent-pool` label is only for display)) are tiered: awake and under 60% CPU (least-loaded first), asleep (exec wakes them), provision fresh, then at the plan cap share the least-loaded busy machine in the same project trust domain. Stats reads never wake a sleeping machine.
3. **Pool isolation.** The router only touches machines it provisioned itself: membership is the persisted id list, written solely by the create path, never the display label (which is user-editable). A machine the user made and named by hand is never drafted into agent work, even if it is renamed `agent-pool`; `--machine <id>` is the explicit opt-in.
4. **Deterministic contract.** `--machine <id>` pins, `--new` forces a fresh machine, the remote exit code passes through, `--json` returns `{machine, created, exit_code, stdout, stderr, ...}`.

Supporting primitives shipped alongside: `vm push` / `vm pull` (chunked,
digest-verified file transfer over exec, works on any managed machine with a
shell, no SSH), and `vm wait` (readiness gate).

Machine creation is a warm claim, not a slow provisioning ceremony. The route
request claims a scrubbed machine for the requested image family and persistence
profile, attaches a clean home volume when needed, and returns after one
daemon-ready probe. Target p50 is under 3 seconds and p95 is under 10 seconds.
If the warm pool is empty, the request returns a durable operation immediately
and the client follows it by default. The router does not issue a feature-list
request before routing.

## Why model routing is the template

The CodeRouter service already solved this shape for model work: a managed
edge, a per-team and model-family coordinator, and model routes, with the
control plane owning durable state and billing. Model families are data in the
shared public contract. Agents can therefore receive the same machine story
without the machine router knowing account secrets or endpoint names. The
machine router consumes the shared client and action IDs; it does not import a
command frontend or an installed binary.

Patterns to carry over verbatim when the router graduates server-side:

| coderouter pattern | machine-router analogue |
|---|---|
| Sticky `conversationKey` derived from headers → body → hash fallback, always non-empty | Work key from agent session id → repo+branch → cwd hash (v1 ships the cwd hash) |
| Tier ladder: subscription OAuth → BYOK → managed; never a cooling credential | Warm machine → sleeping machine → fresh provision → shared busy machine; never a quarantined one |
| Headroom + expiry-pressure scoring, deterministic final tie-break | CPU/RAM headroom + "reservation about to lapse" pressure, stable id tie-break (unit-testable without mocks) |
| Health windows from response headers + adaptive active probing; 429 → exponential cooldown, repeated 401 → quarantine | Normalize backend capacity errors, exec failures, and disk-full into one health state; probe on a traffic-adaptive cadence; two strikes → reprovision, not retry-forever |
| In-request failover with an exclusion list and an explicit replay budget | Re-route a *fresh* command to the next machine transparently; never silently replay a half-streamed one |
| Control plane pushes full versioned `PoolConfig`; the coordinator lazy-loads it on cold start; usage flushes back batched and deduplicated, response carries fresh balance | Same split: Postgres owns inventory, quotas, and billing; a per-team `MachineCoordinator` owns live leases and health; machine minutes flow back as deduplicated events against the account's usage ledger |
| Credential never reaches the caller; only `x-coderouter-credential: <class>` is echoed | The agent may learn the machine *class* it got, never raw machine addresses or credentials |

## v2: control-plane linkage (next)

The concrete wiring, in dependency order:

1. **`vm run` learns a session work key.** Accept `--work-key <id>` and default it from agent session env (`CMUX_WORKSPACE_ID`, Claude/Codex session ids) before the cwd hash, so parallel agents in one repo get their own lanes ("chunking" across machines falls out of distinct work keys).
2. **Move the binding store server-side.** `vm.route` socket method → `POST /api/vm/route` with `{workKey, preconditions}` returning `{machineId, created}`; the web control plane owns bindings and the pool, so routing is consistent across the user's Macs and future headless callers. The CLI store becomes a cache.
3. **`MachineCoordinator` per team** (mirroring `PoolCoordinator` per `team:family`): live inventory, leases with TTL, health windows, scale-out decisions against plan entitlements (`maxActiveVms`), machine-minute metering back to billing.
4. **Keep model and compute authority separate.** A guest receives a VM-local
   model endpoint, not a key. A composite command uses the authenticated Cloud
   profile to request a separate, short-lived machine lease after team policy
   passes. The lease and model action may share one request and usage receipt,
   but they have separate scopes, revocation, and audit records. Reusing one
   authority for both planes would let model access create or destroy machines.
5. **Open-endpoint gap.** Keep model endpoint definitions in the CodeRouter
   contract, not in the machine router. A machine may later serve an
   OpenAI-compatible endpoint, and the two planes can compose without exposing
   deployment details to the agent.

## Non-goals

- The router never deletes machines to make room; at the plan cap it degrades to sharing and tells the user.
- No scheduler-style bin-packing of arbitrary jobs; the unit is "an agent's working session", which is what stickiness optimizes.
- The router never places two project trust domains in one VM. Same-project
  workspaces can share caches and declared application services. Mutually
  untrusted projects use separate warm machines or forks.
- The router never gives a VM a route to the Mac. The host can start an exact
  attach or projection and receive established replies only.
