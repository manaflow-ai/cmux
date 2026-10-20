# cmux next: org workflows on tenant VMs (design)

Status: design, 2026-10-20 (a203). Ask (Lawrence, Oct 20): "dynamic workflows for basically
all the automations I want to have in my organization, so there is some determinism", on
Freestyle, tenant-based. Builds on automations-plan.md (P12-P14), automations-runtime.md,
automations-billing.md and cloud-automation.md; it does not replace them.

## 1. What "dynamic but deterministic" means here

- **Dynamic:** a Chief or a person writes or edits a workflow at any time, from chat or the
  form, without a deploy of cmux.
- **Deterministic:** a run executes one frozen version of that workflow. The step graph,
  the inputs, the machine, the commands and the prompts are fixed when the run starts. Every
  step's result is journaled. A retry or a replay never runs a finished step again; it reads
  the journal. A model's answer is not deterministic, so an agent step is an *activity*
  (Temporal's word): its output is recorded once and every later step sees the recorded value.

## 2. Requirements

| # | Requirement |
|---|---|
| R1 | Versioned specs: every edit makes a new version; a run pins one version. |
| R2 | Explicit steps in a fixed graph; no step can add steps at run time. |
| R3 | Triggers: cron, webhook, GitHub event, chat message, manual, continue. |
| R4 | Idempotent, replayable runs with logs and a timeline; cancel, retry, approve. |
| R5 | Agent steps (Claude, Codex, OpenCode through acpmux) inside the fixed graph. |
| R6 | Per-tenant isolation: a tenant's steps run only on that tenant's machines. |
| R7 | Credits: every step, VM minute and model call is metered to the tenant; a hard cap stops a run. |
| R8 | A Chief can create, run and read workflows through the same ops as a person. |

## 3. Options

### A. Extend the cmux-next automations runtime with machine and agent steps (picked)

The runtime already exists: one SchedulerDO per team holds definitions (versioned, `automation.deploy`
bumps the version), triggers (cron, manual, webhook, event, message, continue, presence) and
run rows; one Cloudflare Workflow (`AutomationRunWorkflow`) per run owns the steps, with
durable `step.do` results, sleeps, retries and deduped reports; `UsageMeterDO` meters and caps
per team. What it lacks is a way to do real work on a machine: `agent_prompt` bodies fail with
`body.unsupported` ("needs machine placement") and the `steps` body has only `sleep`, `note`
and `op`. Option A adds two step types that run on one of the team's own Cloud machines
(CloudDO, Freestyle):

- `machine`: one fixed shell command on a named machine of the team, with a timeout.
- `agent`: one acpmux turn (`claude`, `codex` or `opencode`) on that machine, with a fixed
  prompt.

Each is one durable `step.do` keyed `cmux:machine-<i>` / `cmux:agent-<i>`, so a replay
returns the journaled result. Fit: R1-R8 all reuse existing parts; only the two step types and
one CloudDO RPC are new.

### B. Temporal (self-hosted on a Freestyle hub VM)

Deterministic workflow code plus activities, the strongest replay model. Costs: a cluster to
run (server, Postgres or Cassandra, Elasticsearch for visibility), workflow code must be
deterministic TypeScript or Go written by a Chief (a non-deterministic line breaks replay),
and tenancy is namespaces on a shared cluster. Rejected: a second durable engine beside
Cloudflare Workflows, and an operations load we don't have.

### C. Inngest-style event functions (already present as the `code` body)

Tenant code at a pinned commit, `step.run` memoized per step, triggered by events. The
`code` body (Tier 1 Dynamic Workers) is this model. It stays the path for logic that needs
branches and loops. It is not the default for org automations: it needs a code repository,
a bundle and a deploy per change, and Chiefs write YAML-like specs more reliably than code.

### D. GitHub Actions per tenant (self-hosted runners on Freestyle)

Familiar YAML, triggers from GitHub. Costs: every tenant needs a GitHub repository and
runner registration; chat, cron precision and credits are outside GitHub; logs live in
GitHub; a non-GitHub team cannot use it. Rejected as the core; GitHub events stay a trigger
(R3) through the existing `event` trigger and ConnectionDO.

### E. HQ `tools/freestyle-workflow` (Claude Workflow API on VMs)

A script engine (`agent`, `parallel`, `pipeline`) with one VM per job. No journal, no resume,
no triggers, no tenancy, one shared provider key. Good for HQ fan-out jobs; rejected for
tenants.

### Comparison

| | Determinism | Dynamic edit | Agent steps | Tenancy and credits | Ops cost |
|---|---|---|---|---|---|
| A cmux automations + machine/agent steps | journaled `step.do`, fixed graph | spec edit = new version | yes (acpmux on the team's VM) | SchedulerDO and CloudDO per team, UsageMeterDO | none new |
| B Temporal | full replay of code | needs code | as activities | namespaces, own metering | cluster |
| C Inngest-style code | memoized steps | commit + deploy | through `env.cmux` later | per team | none new |
| D GitHub Actions | per job, no replay | YAML commit | via runner | repo per tenant | runners |
| E freestyle-workflow | none | script | yes | none | none |

## 4. Design of option A

### 4.1 Spec

A `steps` body, up to 50 steps, frozen per version:

```json
{ "type": "steps", "steps": [
  { "type": "machine", "machine": "vm_…", "command": "git -C /work/repo pull && git -C /work/repo log -5 --oneline", "timeout_seconds": 120 },
  { "type": "agent", "machine": "vm_…", "harness": "claude", "prompt": "Summarize these commits for the team channel.", "input_from": 0, "timeout_seconds": 600 },
  { "type": "op", "op": "automation.run", "params": { … } }
] }
```

- `input_from` (optional) names an earlier step. Its journaled output goes to this step's
  stdin (machine) or after the prompt (agent). Data flows only through the journal, so a
  replay sees the same input.
- Each step's output is the last 8 KiB of stdout; it goes into the run report, the run
  timeline and the journal.
- A non-zero exit, a timeout, or a machine that is not the team's ends the run as `failed`
  with a code (`machine.exit`, `machine.timeout`, `machine.not_found`, `machine.not_running`).

### 4.2 Execution

`AutomationRunWorkflow` runs a `machine` or `agent` step inside `step.do`. The step calls
`CloudDO.automationExec(team, machine, command, stdin, timeoutMs)`. CloudDO looks the machine
up **in the run's own team** (the DO is per team, so another team's machine id is simply not
found), requires `running`, and runs the command through its guarded driver
(`execStdin`). The prompt and step input travel on stdin, never in the command line. The
command gets `CMUX_RUN`, `CMUX_STEP` and `CMUX_STEP_KEY` (`step:<run>:<i>`) so a guest script
can dedupe its own side effects.

Retries: a `machine` step retries twice on a provider failure (no answer, 5xx) because the
command never started; it does not retry a non-zero exit. An `agent` step never retries on
its own: a model turn may have side effects; `run.retry` makes a new run.

### 4.3 Triggers

Unchanged: cron (with tz), manual, webhook (signed ingress `automation-hook.ts`), event
(GitHub and other integrations through ConnectionDO), message (a chat rule in a
conversation), continue, presence. A Chief starts one with `automation.run`.

### 4.4 Isolation and credits

- A run only reaches machines of its owner team (CloudDO is per team). There is no
  cross-tenant key: the provider key stays in the Worker; the guest sees only its own
  model-plane token.
- One credits model: Cloud credits (USD, integer micro-dollars in the team's UsageMeterDO,
  topped up through credits-checkout.ts) are the only unit. Every usage line converts to
  credits there: steps (`automation.steps`), sandbox time (`vm.seconds` by size), model tokens
  (model plane). Classic Cloud's Stack Auth "create credits" are not used by cmux-next and are
  not extended. A machine step counts its wall time as sandbox seconds (and against
  `budget.vm_minutes`); agent turns are metered by the model plane.
- Unit costs to price from (provider cost, before margin): a 2 vCPU / 4 GiB sandbox is about
  0.13 USD per running hour, 4 vCPU / 8 GiB about 0.26 USD (scaled from the 193 USD/month
  hub bill; paused machines cost storage only). Create to running: 2.1 s measured. One
  short Claude turn through acpmux: 12.6 s wall. The hard USD cap is checked before each machine or agent step; at the cap the run
  stops at that step boundary (`usage.cap`) and the run's error carries the team's top-up
  link (credits-checkout.ts).

### 4.5 Chief authoring

A Chief writes the JSON spec, calls `automation.create` / `automation.update` (a new
version) and `automation.run`, and reads `automation.runs.list`. The validation errors are
typed, so a Chief can fix a spec in one more turn.

## 5. Built in this change

- Protocol: `machine` and `agent` step types (`backend/packages/protocol/src/automations.ts`).
- `backend/apps/api/src/automation-machine.ts`: the deterministic command builder, the
  `input_from` resolver and the step executor over a `MachineExec` port.
- `AutomationRunWorkflow`: the two step types as durable steps, failure codes, reports.
- `CloudDO.automationExec`: the team-scoped exec.
- Tests first (red, then green). An example spec (`plans/cmux-next/examples/org-workflow-commit-digest.json`)
  run step by step on a real tenant VM (section 7).

## 6. Not built yet

- Run timeline UI and the dashboard form (automations-plan slice 12).
- Metering VM minutes per machine step into UsageMeterDO (4.4) and the cap check before it.
- A machine created per run (today the spec names an existing machine of the team).
- acpmux in the Cloud image (it was uploaded by hand for the proof).
- A staging run through the deployed Worker.

## 7. Proof (2026-10-20)

- Tests (workerd, on a Freestyle VM): `test/automation-machine.test.ts` 7 pass, with
  `automation-caps` and `automation-code` 22 pass in all; `tsc` clean; `catalog:check` clean
  after regenerating the catalog, the TS client and the Rust wire types; `cargo check -p
  cmux-cloud-wire` clean. The workerd test runs a real `AutomationRunWorkflow` against the
  team's CloudDO: a step on a machine the team does not have ends the run `failed` with
  `machine.not_found`.
- Real tenant VM: the example spec
  [examples/org-workflow-commit-digest.json](examples/org-workflow-commit-digest.json) ran with
  the same step executor (`automation-machine.ts`) through
  [examples/run-on-classic-vm.ts](examples/run-on-classic-vm.ts) on Lawrence's tenant VM
  `vm-0a28ba3e264e46aebdfcb89cbcfac259` (2 vCPU / 4 GiB; deleted after), run
  `run_digest0a203000000003`:

  | Step | Type | Time | Result |
  |---|---|---|---|
  | 0 | machine: last 5 commits of feat-cmux-next | 0.75 s | 5 lines |
  | 1 | agent: Claude via acpmux, input from step 0 | 13.7 s | a 3-line digest |
  | 2 | machine: save step 1's output | 0.67 s | `saved 3 lines to /home/cmux/digests/run_digest0a203000000003.txt` |

  A replay with the same run id made 0 machine calls and returned the same three outputs from
  the journal. The first two attempts failed honestly (`machine.exit`, `acpmux: not found`):
  the proof port ran as the work user instead of root, and acpmux was not on the login PATH;
  both are fixed (the port uses `sudo -n` like the driver's root exec; the agent command puts
  `~/.local/bin` first on PATH, test first).
- Not proven: a run through the deployed staging Worker (needs a staging deploy and a staging
  session; next step), metering of sandbox seconds per step, acpmux in the image.
