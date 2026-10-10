# Cloud work environments

Status: design proposal.

Cloud sessions currently make each terminal solve the same setup problems again:
installing hooks, explaining a sandbox denial, finding credentials, and deciding
which machine-local environment variables to reuse. A person should configure a
work environment once, then start terminals and agent sessions from that
environment with an inspectable capability boundary.

## Boundary

The reusable object is a **work environment** owned by one user. It is attached
to a project or workspace group and can be bound to one machine or a machine
family. It is deliberately larger than a single terminal and narrower than an
account-wide global setting.

```text
user
└── work environment: acme-web / cloud-dev
    ├── machine binding: warm cloud machines in the user's pool
    ├── setup recipe: toolchain, packages, services, checks
    ├── agent hooks: codex, claude, ACP adapters
    ├── capability profile: filesystem, network, host tools
    ├── credential references: GitHub, Git, registries, model providers
    └── notification route: this user's devices
```

Every child workspace and agent session records the environment id and a
resolved revision. The sidebar can then answer “why is this session allowed to
do that?” without inspecting shell history.

## Setup and reuse

The first `cmux vm dev` or “Set up work environment” action creates a draft,
detects the repository recipe, and asks once for capabilities that cannot be
inferred. Applying the draft produces an immutable revision:

```json
{
  "name": "acme-web/cloud-dev",
  "project": "acme-web",
  "machineScope": "user-pool",
  "setup": ["bun install"],
  "services": ["postgres"],
  "hooks": ["codex", "claude"],
  "capabilities": ["repo-write", "network:dev-ports"],
  "credentials": ["github:acme", "npm:acme"],
  "checks": ["bun test"]
}
```

Starting another workspace with the same environment is idempotent. It reuses
the machine-local materialized setup when its recipe and lockfile hashes match,
and reports what changed when a new revision is needed. A denied operation emits
an actionable capability request tied to the environment; approving it updates
the next revision instead of requiring repeated per-process sandbox overrides.

## Credentials and security

Credential entries are references, never raw values in a repo, workspace name,
command line, or terminal transcript. The control plane stores the user's
credential, issues a short-lived environment-scoped lease, and injects it only
for the matching machine/workspace process. GitHub access should therefore be
scoped as `(user, environment, provider, repository policy)`, while a machine
is only a materialization target. Rotation and revoke invalidate leases and are
visible from the environment detail view.

The environment capability profile is deny-by-default. It names the allowed
filesystem roots, network destinations/ports, host integrations, and agent
hooks. A session inherits a snapshot of that profile; changing the environment
does not silently alter an already-running session. The UI shows both the
resolved revision and any pending setup action.

## CLI/API shape

The first implementation can sit on existing `vm env`, `vm hooks`, `vm dev`, and
machine identity primitives:

```text
cmux vm env create <name> [--project <repo>] [--machine-scope user-pool]
cmux vm env setup <name> [--from .cmux/cloud.json] [--interactive]
cmux vm env status <name> [--json]
cmux vm env bind <workspace> <name>
cmux vm env credentials <name> list|attach|revoke
cmux vm env capability <name> request|grant|revoke
```

The daemon should expose the same records through `environment.get/list` and
include `environmentId`, `environmentRevision`, and resolved capability/auth
summaries in workspace and agent snapshots. Existing machine-local `vm env`
remains the low-level materialization primitive during migration.

## Delivery order

1. Add environment identity and revision metadata to workspace/agent snapshots;
   surface it in the sidebar and Cloud tree.
2. Implement local, machine-scoped setup using the existing recipe and hook
   primitives; persist a redacted manifest and lockfile hashes.
3. Add one-time capability requests and reusable approvals, with reconnect and
   retry handling.
4. Move GitHub/Git and model credentials behind environment-scoped leases and
   show provenance/rotation state. See [cloud-credential-leases.md](cloud-credential-leases.md)
   for the lease, broker, and revocation contract. Until that contract ships,
   `gh` and SSH remain machine/target-home scoped.
5. Add machine-pool binding, service recipes, and environment cloning for
   fan-out.
