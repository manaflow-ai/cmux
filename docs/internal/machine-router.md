# Machine router: invisible cloud machines for coding agents

Status: v1 shipped in the CLI (`cmux vm run`); this doc records the design and the path to the control-plane version that pairs with cmux-coderouter.

## Goal

An agent (Claude Code, Codex, or any open-source-model harness) should be able to say *"run this in the cloud"* and never think about machines: no ids, no capacity, no setup. The router picks the computer, provisions when needed, keeps warm state where the work is, and meters usage — the same way cmux-coderouter makes model credentials invisible behind a `crk_` key.

## v1 — CLI-side router (this repo, shipped)

`cmux vm run [--sync] [--pull <remote>] -- <command...>` routes over the existing `vm.*` socket methods:

1. **Sticky first.** A local binding store (`~/.cmuxterm/vm-run-bindings.json`) maps a work key — SHA-256 of the caller's directory — to the machine that last ran that work. A bound, ready pool machine wins outright: it holds the synced checkout, installed dependencies, and build caches. This mirrors coderouter's sticky `conversationKey → credential` assignment, which exists for the same reason (warm state is throughput).
2. **Then load-aware scoring.** Pool machines (persisted pool id list (`~/.cmuxterm/vm-run-pool.json`; the `agent-pool` label is only for display)) are tiered: awake and under 60% CPU (least-loaded first) → asleep (exec wakes them) → provision fresh → at the plan cap, share the least-loaded busy machine. Stats reads never wake a sleeping machine.
3. **Pool isolation.** The router only touches machines it provisioned itself — membership is the persisted id list, written solely by the create path, never the display label (which is user-editable). A machine the user made and named by hand is never drafted into agent work, even if it is renamed `agent-pool`; `--machine <id>` is the explicit opt-in.
4. **Deterministic contract.** `--machine <id>` pins, `--new` forces a fresh machine, the remote exit code passes through, `--json` returns `{machine, created, exit_code, stdout, stderr, ...}`.

Supporting primitives shipped alongside: `vm push` (SCP over private userspace WireGuard) / `vm pull` (digest-verified chunks over exec), and `vm wait` (readiness gate).

## Machine-local admission handoff

Routing and physical ownership are separate decisions.

For a CMUX-owned node that uses Glaeda as its execution-side admission layer,
the router result is either a candidate-node choice or external reservation
evidence. The semantic workload still crosses the adapter without raw host
paths, cache directories, cgroup properties, arbitrary environment, or a
caller-authored shell string.

Candidate-only flow:

```text
router selects node A
-> node A receives caller identity + semantic workload
-> node A freshly checks drain/pressure/interference/resources
-> local physical lease accepted or refused
```

Reserved-node flow:

```text
MachineCoordinator/controller holds reservation for node A
-> adapter presents bounded owner/scope/generation/expiry evidence
-> node A validates the reservation and current local state
-> local physical lease binds beneath that reservation
```

The control-plane lease prevents another fleet scheduler from assigning the
same globally scarce node allocation. The machine-local lease prevents GitHub
Actions, `cmux-ci`, direct agent work, operator commands, or another adapter
from colliding over native build lanes, heavy slots, project locks, publisher
slots, or resident workspaces after they reach the node.

A route or reservation never becomes permission to bypass fresh machine-local
admission. Process names, runner liveness, and apparent idleness never establish
ownership. A local refusal can return pressure/drain/conflict evidence to the
router so it may choose another eligible target under its own replay rules.

Caller identity remains independent from the semantic operation. Two callers
may ask for the same operation while retaining separate request namespaces;
same external request strings from unrelated callers stay independent.

## Why coderouter is the template

cmux-coderouter (`manaflow/cmux-coderouter`) already solved this shape for model credentials: Worker edge → per-`team:family` `PoolCoordinator` Durable Object → upstreams, with the control plane owning durable state and billing. Model coverage there is exactly the set we care about — **Claude** (Anthropic OAuth/BYOK/managed via `/anthropic/*`), **Codex** (`/codex/*`, OAuth), and **open-source models** through OpenAI-compatible BYOK families (Groq for Llama/Kimi, z.ai for GLM, OpenRouter for anything, plus Gemini/xAI) — so agents on any of those model families can be given the same machine story.

Patterns to carry over verbatim when the router graduates server-side:

| coderouter pattern | machine-router analogue |
|---|---|
| Sticky `conversationKey` derived from headers → body → hash fallback, always non-empty | Work key from agent session id → repo+branch → cwd hash (v1 ships the cwd hash) |
| Tier ladder: subscription OAuth → BYOK → managed; never a cooling credential | Warm machine → sleeping machine → fresh provision → shared busy machine; never a quarantined one |
| Headroom + expiry-pressure scoring, deterministic final tie-break | CPU/RAM headroom + "reservation about to lapse" pressure, stable id tie-break (unit-testable without mocks) |
| Health windows from response headers + adaptive active probing; 429 → exponential cooldown, repeated 401 → quarantine | Normalize provider capacity errors/exec failures/disk-full into one health state; probe on a traffic-adaptive cadence; two strikes → reprovision, not retry-forever |
| In-request failover with an exclusion list and an explicit replay budget | Re-route a *fresh* command to the next machine transparently; never silently replay a half-streamed one |
| Control plane pushes full versioned `PoolConfig`; DO lazy-pulls on cold start; usage flushes back batched + deduped, response carries fresh balance | Same split: Postgres owns inventory/quotas/billing, a per-team `MachineCoordinator` owns live leases and health, machine-minutes flow back as deduped events debiting the Stack Auth credit item |
| Credential never reaches the caller; only `x-coderouter-credential: <class>` is echoed | The agent may learn the machine *class* it got, never raw provider addresses or credentials |

## v2 — control-plane linkage (next)

The concrete wiring, in dependency order:

1. **`vm run` learns a session work key.** Accept `--work-key <id>` and default it from agent session env (`CMUX_WORKSPACE_ID`, Claude/Codex session ids) before the cwd hash, so parallel agents in one repo get their own lanes ("chunking" across machines falls out of distinct work keys).
2. **Move the binding store server-side.** `vm.route` socket method → `POST /api/vm/route` with `{workKey, requirements}` returning `{machineId, created}`; the web control plane owns bindings and the pool, so routing is consistent across the user's Macs and future headless callers. The CLI store becomes a cache.
3. **`MachineCoordinator` per team** (mirroring `PoolCoordinator` per `team:family`): live inventory, leases with TTL, health windows, scale-out decisions against plan entitlements (`maxActiveVms`), machine-minute metering back to billing.
4. **crk_ keys become machine-entitled.** A coderouter key's policy grows `machines: {maxConcurrent, sizes}`; the gateway (or cmux.com API accepting `crk_` auth on `/api/vm/route`) lets an agent that already talks to coderouter for Claude/Codex/OSS models get compute with the *same* credential — zero extra setup, one revocation point, one usage ledger.
5. **Open-endpoint gap.** coderouter's upstream bases are hardcoded; when per-team custom OpenAI-compatible endpoints land (vLLM on a routed machine is the natural first case), a machine provisioned by this router can *serve* an open-source model that coderouter then routes to — the two planes compose.

## Non-goals

- The router never deletes machines to make room; at the plan cap it degrades to sharing and tells the user.
- No scheduler-style bin-packing of arbitrary jobs; the unit is "an agent's working session", which is what stickiness optimizes.
