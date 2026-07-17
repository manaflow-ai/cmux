# cmux Orchestration Templates

An **orchestration** is a shareable, versioned package that captures a whole
way of running fleets of coding agents: prompt templates, workspace shapes,
agent command lines, and how task workspaces are provisioned. One user can
publish their setup as a git repo; another installs it and runs it against
their own repositories with their own credentials.

Orchestrations are the packaging/template layer. The fleet runtime engine
(task queue, board, supervision — see issue #7361) is a separate layer that
will consume the same manifests; v1 of `cmux orchestration run` performs a
minimal but real run on its own.

## Quick start

```bash
# Install the first-party example (ships in the cmux repo)
cmux orchestration install Examples/Orchestrations/issue-fleet

# Answer the interview (target repo, concurrency, …), then:
cmux orchestration run issue-fleet \
  --task "Fix the flaky scroll test" \
  --task "Add --json output to cmux top"
```

Each task gets its own git worktree, branch, and cmux workspace (created
unfocused, grouped in the sidebar), with the rendered agent command typed
into a real terminal.

## Package format

An orchestration is a directory, usually a git repository:

```
orchestration.json   # manifest (required, versioned schema)
WORKFLOW.md          # human-readable fleet description
prompts/             # prompt templates with {{placeholders}}
steps/               # (by convention) prompts used by the step chain
layouts/             # optional cmux saved-layout JSON for task workspaces
scripts/             # lifecycle scripts for the script substrate
instructions/        # agent instruction fragments (CLAUDE.md/AGENTS.md additions)
README.md
```

Everything the manifest references is a path relative to the template root;
absolute paths and `..` traversal are validation errors.

### Manifest (`orchestration.json`)

```jsonc
{
  "schemaVersion": 1,                  // required; cmux rejects newer schemas
  "name": "issue-fleet",               // lowercase slug; install dir name
  "version": "1.0.0",                  // X[.Y[.Z]]
  "description": "…",
  "author": "…",                       // optional
  "minCmuxVersion": "0.30",            // optional run-time gate

  "parameters": [                       // install-time interview
    { "key": "repo_root", "prompt": "Repo to work on", "type": "path" },
    { "key": "concurrency", "prompt": "Cap", "type": "int", "default": 3 }
  ],

  "substrate": { "kind": "worktree", "branchPrefix": "issue-fleet" },

  "agents": [                           // command templates, never credentials
    { "id": "claude", "registryAgent": "claude",
      "command": "claude --permission-mode acceptEdits {{prompt}}" }
  ],
  "defaultAgent": "claude",            // optional; defaults to first agent

  "prompt": "prompts/task.md",         // used when there are no steps
  "steps": [                            // optional linear chain (no DAGs)
    { "id": "implement", "agent": "claude", "prompt": "prompts/task.md",
      "success": { "kind": "hook-event", "event": "Stop" },
      "onFailure": { "kind": "retry", "attempts": 1 } }
  ],

  "layout": "layouts/task.json",       // optional saved layout per workspace
  "workflow": "WORKFLOW.md",
  "instructions": ["instructions/AGENTS.md"]
}
```

**Parameters** are the machine-specific inputs (target repo, workspace root,
agent choice, concurrency). Types: `string`, `int`, `bool`, `path` (`~`
expanded), `choice` (with `choices`), `agent` (an id from `agents`). A
parameter without a `default` must be answered before the first run.
Resolved values are stored per-install on the user's machine — never inside
the template. Well-known keys the run path understands: `repo_root`
(required by the git substrates), `workspace_root`, `concurrency`, `agent`.

**Substrates** control how task workspace directories appear:

| Kind | Behavior |
| --- | --- |
| `worktree` | One `git worktree add -b <branch>` per task from `repo_root`. Optional `branchPrefix`. |
| `clone-pool` | Full clones of `repo_root` (v1 provisions a fresh clone per task; pool reuse/reset arrives with the fleet engine). Optional `poolSize`. |
| `script` | The template's `provision` script (default `scripts/provision-workspace`) runs with the target directory as `$1` and `CMUX_ORCHESTRATION*` env vars; it must create the directory. Optional `reset` script (engine-era). The escape hatch for SSH/cloud/anything. |

**Steps** are a linear chain (plan → code → review). Success kinds:
`exit-code` (`code`, default 0), `pr-exists`, `hook-event` (`event`, e.g.
`Stop`). Failure policies: `retry` (`attempts`) or `needs-input`. v1 of
`run` executes the first step only (a note in the plan says so); full chain
execution belongs to the fleet engine.

### Placeholders

`{{name}}` in prompt templates and agent commands. Built-ins, provided per
task at run time:

`{{task}}`, `{{task_index}}`, `{{task_slug}}`, `{{branch}}`,
`{{workspace_dir}}`, `{{issue_number}}`, `{{orchestration_name}}`,
`{{run_id}}` — plus every declared parameter key (e.g. `{{repo_root}}`).

Agent commands may additionally use `{{prompt}}` (the rendered prompt,
shell-quoted) and `{{prompt_file}}` (path of the rendered prompt written to
`.cmux/orchestration-prompt.md` inside the workspace). Unknown placeholders
are validation errors, so typos fail before anything runs.

## Trust model

Enforced in code, not convention:

- **Install never executes template code.** `install`/`update` only clone
  or copy files and parse JSON (`git` against the URL you gave is the only
  process spawned), then validate. Invalid templates never reach the store.
- **First run requires explicit confirmation.** Before a template's first
  run (and again after every `update`), cmux shows the substrate, every
  agent command template, and every script the template would execute, and
  asks for confirmation. `--yes` skips the prompt. Script-substrate
  templates are flagged in that summary. The confirmation is bound to a
  `trust_fingerprint` of the reviewed plan's trust material, so a template
  that changes between review and confirmation is rejected instead of
  silently approved.
- **Templates contain regular files only.** Validation rejects symbolic
  links anywhere in the template — a symlinked prompt or script could
  otherwise resolve outside the template root and leak its target into
  rendered prompts.
- **Templates never contain secrets.** Validation rejects files containing
  obvious credential material (token prefixes, private keys). Agent
  commands run with whatever auth the *user's* machine already has; scripts
  read env/keychain locally.
- **Runs never steal focus.** Workspaces are created unfocused and grouped.

## CLI

```
cmux orchestration init <name> [--dir <path>]
cmux orchestration validate [path]
cmux orchestration install <git-url-or-path> [--ref <branch>] [--force] [--param k=v …]
cmux orchestration list [--json]
cmux orchestration info <name> [--json]
cmux orchestration remove <name>
cmux orchestration update <name>
cmux orchestration configure <name> [--param k=v …]
cmux orchestration plan <name> --task <t> […]
cmux orchestration run  <name> --task <t> [--tasks-file <path>] [--param k=v] [--agent <id>] [--dry-run] [--yes]
```

Store verbs work without a running app; `plan`/`run` need the cmux socket.
`update` re-fetches from the recorded source, keeps your parameter answers
(dropping keys the new version no longer declares), and resets trust
confirmation.

## Socket API

The v2 domain `orchestration.*` follows the standard coordinator patterns:

| Method | Params | Result |
| --- | --- | --- |
| `orchestration.list` | — | `{orchestrations: [{name, version, description, substrate, agents, source, trust_confirmed, unanswered_parameters}]}` |
| `orchestration.info` | `name` | summary + parameters/steps/paths detail |
| `orchestration.plan` | `name`, `tasks` (strings or `{title, body?, issue_number?}`), `params?`, `agent?` | `{plan, trust_confirmed, trust_fingerprint}` |
| `orchestration.run` | plan params + `confirm_trust?` + `confirm_fingerprint?`, routing selectors | `{status: "started", run_id, group, workspaces…}`; errors `needs_confirmation` (with the trust summary) until confirmed with the reviewed plan's fingerprint |

## Storage

```
~/.cmuxterm/orchestrations/<name>/
  template/      # pristine copy/clone of the template
  install.json   # source, install/update times, resolved parameters,
                 # trust confirmation — per-machine state, never shared
```

## v1 scope

Implemented: package format + validation, install/list/info/init/remove/
update/configure, parameter interview, trust gate, and real runs for the
`worktree`, `clone-pool` (clone-per-task), and `script` substrates —
workspaces provisioned sequentially off the main thread, grouped, unfocused,
agent command typed into the terminal (or delivered as the layout's setup
command when the template ships a layout).

Deferred to the fleet engine (#7361): step-chain execution and supervision,
clone-pool reuse/reset, issue-queue work sources, and applying
`instructions/` fragments to workspaces automatically.

The living fixture is
[`Examples/Orchestrations/issue-fleet`](../Examples/Orchestrations/issue-fleet);
`CmuxOrchestration` package tests validate and plan it on every CI run.
