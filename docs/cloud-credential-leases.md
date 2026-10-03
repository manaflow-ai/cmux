# Cloud credential leases

Status: design proposal. Current Cloud sessions do **not** provide per-workspace
or per-user GitHub and SSH credentials. `gh` reads the machine's `$HOME`, and
SSH reads the target machine's `$HOME`; a status label cannot change that
boundary. This document defines the contract required to replace it without
copying a bearer token into an agent workspace.

## Scope

A credential reference belongs to a signed-in user and a named work environment:

```text
(user, environment, provider, repository policy)
```

The environment is larger than a terminal and can be reused by child workspaces
and fan-out agents. A machine is only the materialization target. Machine-wide
`gh auth login`, an SSH key in `~/.ssh`, or a value in `vm env` remains outside
this contract and must continue to be reported as `machine_home` until migrated.

The first providers are GitHub and SSH. GitHub is repository-policy scoped; SSH
is host and account scoped. Neither provider may receive a Stack access or
refresh token.

## Lease record

The control plane stores provider credentials encrypted at rest and never
returns plaintext to a client, VM, workspace, terminal, or agent. It creates a
short-lived lease containing metadata only:

```json
{
  "id": "lease_…",
  "environment_id": "env_…",
  "user_id": "user_…",
  "provider": "github",
  "repository_policy": {"repositories": ["acme/web"], "permissions": ["contents:write", "pull_requests:write"]},
  "machine_id": "vm_…",
  "workspace_id": "workspace_…",
  "expires_at": "2026-10-02T01:00:00Z",
  "revoked_at": null,
  "state": "active"
}
```

Persist a hash of the lease bearer and a provider credential reference, never
the bearer itself. A lease is accepted only when user, environment revision,
machine, workspace, provider, repository policy, and expiry all match at the
injection boundary. A child agent receives a snapshot of the environment
revision, so changing an environment does not silently change a running
process.

The only lease mutations are `issue`, `renew`, and `revoke`. `revoke` commits
the denied state before provider cleanup; retries are safe and an expired lease
is denied even if cleanup is delayed. Sign-out, environment deletion, machine
deletion, and repository-policy removal revoke matching leases.

## Materialization

An edge or machine-side broker exchanges the lease for a provider session at
process start. It injects a temporary environment or socket into exactly one
workspace process and removes it when that process exits. It must not write
`~/.config/gh`, `~/.ssh`, shell history, command lines, or terminal output.

GitHub materialization should use a broker-backed `gh` wrapper or Git credential
helper that checks repository path before each request. SSH materialization
should use a per-process `IdentityAgent`/`ProxyCommand` and short-lived signing,
rather than copying a private key. Both helpers fail closed outside policy.

Snapshots, forks, and machine-home setup are not lease materialization. They
must never contain provider secrets; snapshot creation should reject or scrub
legacy `~/.config/gh` and `~/.ssh` files for managed environments.

## API and observability

The control plane should expose environment-scoped operations:

```text
environment.credentials list <environment>
environment.credentials attach <environment> <provider-reference> [policy]
environment.credentials revoke <environment> <lease-or-reference>
environment.credentials status <environment>
```

Responses contain provider, environment revision, policy summary, binding,
expiry, and state. They never contain tokens, private keys, cookies, or an
unredacted provider response. `cmux auth status --json` should expose current
machine-home boundaries and active lease summaries, for example:

```json
{"credential_boundaries":{"github_cli":"machine_home","ssh":"remote_home","environment_leases":"available"},"leases":[]}
```

Until the broker exists, `environment_leases` must be `unavailable` rather than
claiming machine-home credentials are isolated.

## Delivery order

1. Add immutable environment id and revision to workspace, agent, and machine
   snapshots; make `auth status` report the boundary honestly.
2. Add encrypted provider references and lease rows with user, environment,
   machine, workspace, policy, expiry, and revocation indexes.
3. Add an edge broker and GitHub helper/SSH agent materializers. Keep the
   existing machine-home path as explicit compatibility mode.
4. Gate `vm repo clone`, `vm agent`, fan-out, and PR operations on a lease when
   an environment requests managed credentials.
5. Add snapshot scrub/rejection, rotation, revocation, and audit events.

The implementation is complete only when two workspaces on one machine can
attach different repository policies and each helper is denied after the other
lease is revoked. Until that test and the edge broker land, per-user or
per-work-environment GitHub and SSH isolation is not implemented.
