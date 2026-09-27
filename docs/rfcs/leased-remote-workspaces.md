# RFC: leased remote workspaces

Status: draft  
Issues: #14909, #14910, #14854  
Cross-repo: manaflow-ai/cmuxterm-hq#778, teamleaderleo/glaeda#1298

## Summary

CMUX should make an idle remote machine feel like another place the user's work can live.

The first milestone is intentionally smaller than moving an already-running Claude/Codex session:

> **Acquire or choose a machine, create a persistent CMUX workspace there, and use it from Mac/iPhone like normal CMUX work.**

This solves the immediate developer capacity problem and establishes the machine/session path needed by later agent movement.

## Existing pieces

The implementation should compose current behavior.

CMUX already has:

- `workspace.ssh.open` for TTY `cmux ssh` through cmux-tui;
- persistent remote workspace/session descriptors;
- stable surface and workspace IDs;
- `cmux current` and Find Work;
- remote reconnect;
- predictive local echo;
- iOS remote terminal attachment;
- background `surface.read_text` / `read_screen` demand-start;
- agent/session metadata;
- session snapshot/restore hardening;
- agent-aware `terminal.paste` locally.

The fleet side already has expiring reservations. This RFC does not define a new fleet scheduler.

## Existing generic machine boundary

This work should promote existing CMUX machine abstractions instead of creating a fleet-specific path.

### Surface machine identity

`SurfaceMachineID` already distinguishes:

```text
local
cloud
ssh
device
```

An SSH cmux-tui connection already becomes a `.ssh` machine and uses the shared `SurfaceCatalog`.

### Shared SSH/Cloud surface provider

`SSHTuiWorkspaceCoordinator` describes its job directly:

> Compose SSH carriers with the same terminal graph and native projections as Cloud.

It registers the same `CmuxTuiSurfaceProvider` family used by managed machines. Remote work therefore already has a provider-neutral graph once a connection exists.

### cmux-tui machine provider

`cmux-tui/spec/machine-provider.md` already defines implemented v0/v1 machine-provider contracts.

The important v1 boundary is:

```text
provider
  owns discovery/auth/authz/lifecycle/connection
CMUX
  owns machine/workspace/session UI
mux
  owns the remote workspace/terminal graph
```

It already supports:

- provider-stable machine ids;
- scopes;
- machine create/open;
- machine/workspace lifecycle capabilities;
- one-use connection tickets;
- `connect-external-machine-v1`;
- provider-owned workspace catalogs.

The spec explicitly states that user-owned machines and Cloud VMs use the same descriptor/open boundary.

That should be the center of the self-hosted direction.

### Lease is availability, not identity

A Glaeda developer lease says:

> this owned machine is available to this caller until T

It does not define the machine's CMUX identity.

Keep these separate:

```text
machine
  stable identity
  provider / connection
  capabilities

availability
  free / busy / reserved / draining / offline
  lease owner / purpose / expiry when applicable
```

The same mini can serve CI, a developer, and later an agent pool at different times without becoming three machines.

## User journey

### 1. Get a machine

Possible sources:

- registered SSH host;
- Glaeda developer lease;
- CMUX Cloud VM;
- later Hive machine registry.

The first implementation may start with a concrete SSH host while carrying a stable machine reference that can later point at a richer registry row.

### 2. New Workspace on Machine

UI surfaces may include:

- sidebar machine context menu;
- command palette;
- machine picker;
- current-work result;
- CLI.

Conceptual action:

> **New Workspace on <machine>**

Result:

- one CMUX workspace;
- remote terminal owned by cmux-tui;
- persistent remote session;
- machine association stored with the workspace;
- normal sidebar/current-work presence.

The machine is placement. It is not the workspace identity.

### 3. Start work

The workspace may start:

- shell;
- Claude;
- Codex;
- another existing harness launcher.

For the first version the user is starting a new provider/harness session remotely.

No provider session migration is required.

### 4. Detach and reconnect

Closing the Mac client does not end the remote work.

Reopen CMUX:

- workspace restores;
- same remote session reattaches;
- stable workspace/surface IDs remain;
- agent state is recovered where current hooks/session projection support it.

The phone should be able to attach to the same live workspace.

### 5. Release machine

If the machine came from a bounded lease, CMUX shows lease state/expiry.

Releasing the fleet machine and stopping/detaching work are separate operations.

The UI should prevent the dangerous mental shortcut:

> old workspace exists, therefore I still own this machine.

After a lease expires/releases, the workspace may remain visible but execution should be marked unavailable until it is placed somewhere authorized again.

## Identity model

Keep the objects separate.

```text
workspace
  -> runtime/session
      -> current machine placement
          -> transport connection
```

For agent work:

```text
workspace
  -> harness/provider session
      -> CMUX runtime/session
          -> machine
```

This distinction is required by #14854 later.

### Workspace identity

Stable CMUX user-facing location in sidebar/current-work.

Survives:

- client restart;
- reconnect;
- machine connection loss.

### Machine identity

A stable reference to the execution host.

First SSH implementation can derive one from a normalized SSH configuration, but the stored model should leave room for:

- registered Mac;
- Linux host;
- Cloud VM;
- Glaeda node;
- Hive machine.

### Remote session identity

cmux-tui session/runtime identity used to attach to actual PTY work.

Do not use an SSH TCP connection as the identity.

### Provider session

Claude/Codex/etc. identity remains provider/harness-owned.

## Machine descriptor

A minimal first record could include:

```text
id
kind = ssh
display name
host/config reference
user
home/path compatibility hints
capabilities if known
lease metadata if present
```

Avoid storing passwords/private keys.

SSH authentication continues through existing auth behavior.

## Lease metadata

When a machine comes from a Glaeda lease, the workspace/machine projection may carry bounded metadata:

```text
source: glaeda
owner
purpose
expires_at
class
node reference
```

This is presentation/correlation state, not authority to edit Glaeda files.

A future release action should call the reviewed adapter/CLI rather than mutate reservation state directly.

## Current-work

Remote leased work must use the same current-work projection.

Expected fields:

- stable workspace ID;
- stable surface IDs;
- machine/remote placement;
- cwd/repository;
- agent key/state;
- attention;
- freshness;
- availability;
- lease expiry if known.

Do not create a second remote-work catalog.

Find Work should be able to jump straight to the workspace.

## Project bootstrap

The first useful workflow is repository work.

Candidate flow:

```text
machine selected
-> choose/open repo
-> remote host fetches/creates checkout
-> create workspace at cwd
-> optionally launch agent
```

Prefer Git semantics for repository state.

Do not automatically copy arbitrary local home-directory state.

For dirty local work, a later helper can transfer:

- exact HEAD/base;
- modified tracked files;
- untracked non-ignored files;
- deletions.

That same helper becomes part of #14854.

## Transport quality

The remote workspace should be comfortable enough that the user stops thinking in terms of SSH.

### Typing

Predictive local echo already addresses ordinary prompt latency.

### Shell environment

Continue making `cmux ssh` match normal interactive login behavior.

### Read/inspect

Background surfaces can already start on demand for reads without changing selected workspace.

### Paste

#14910 owns the major remaining high-bandwidth input gap.

`cmux paste --submit` is the right semantic primitive for large/multiline agent prompts. It should become available to a caller scoped to one authorized remote workspace/surface.

Do not solve this by sending a shell command over SSH.

## Remote paste security boundary

The target authorization should be narrower than generic remote control-socket forwarding.

A remote paste call must prove:

- caller owns/is allowed to interact with the remote workspace;
- surface belongs to that workspace/session;
- target is current;
- payload is bounded;
- only paste/submit semantics are granted.

No global workspace enumeration or arbitrary socket method should be implied.

The host-side Ghostty paste path remains responsible for bracketed-paste encoding and unsafe control-byte handling.

## Failure states

### Host unreachable

Keep workspace identity and show unavailable/reconnect.

### SSH authentication needed

Use existing foreground auth path.

### Remote cmux-tui session lost

Report the missing session and offer a new one.

Do not silently bind another PTY.

### Lease expired

Show expired/unavailable placement.

Do not automatically extend fleet ownership.

### Machine returned to CI

Do not auto-run personal startup commands merely because CMUX reconnects.

A new lease/placement is required.

### Client crash/restart

Workspace/session restore should reattach through durable descriptors and current machine/session evidence.

## Relationship to session movement

#14854 starts where this RFC ends.

This RFC:

```text
local work remains local
new work starts on remote machine
```

#14854:

```text
existing provider session on A
-> quiesce
-> carry dirty source + provider state
-> fence
-> resume on B
```

The remote workspace path should be the destination attach mechanism for that later move.

## Implementation slices

### A. Machine-first workspace creation

- machine descriptor;
- UI/CLI picker;
- call existing `workspace.ssh.open`;
- persist workspace-machine association;
- restore/reconnect.

### B. Current-work projection

- show machine placement;
- show availability;
- show lease metadata where provided.

### C. Scoped remote paste

Implement #14910.

### D. Repo bootstrap

Optional clone/fetch/cwd materialization.

### E. Lease integration

Consume Glaeda developer lease output.

Start as an explicit action:

> Borrow a mini and open workspace

Automatic placement comes later.

## Dogfood acceptance

On a laptop under real resource pressure:

1. borrow/choose one 48 GB mini;
2. create remote CMUX workspace;
3. launch Claude/Codex;
4. run a representative local-memory-heavy build remotely;
5. use predictive echo;
6. use multiline paste/submit;
7. detach Mac;
8. attach from iPhone;
9. reconnect from Mac;
10. locate work through Find Work;
11. restart CMUX and restore;
12. release the mini;
13. confirm the workspace no longer assumes the released machine is authorized.

Measure:

- selected machine -> prompt usable;
- reconnect latency;
- time spent dealing with SSH details;
- paste failures/retries;
- memory/CPU relief on the local Mac.

## Non-goals

- transparent live VM migration;
- moving a provider session in the first slice;
- automatic preemption;
- making every shell a fleet workload;
- replacing cmux-tui;
- a new current-work database;
- a second machine reservation format;
- silently exposing arbitrary remote control methods.

## End state

The user should think:

> my workspace is on that machine

instead of:

> I opened an SSH terminal to a build box.

Once that feels ordinary, #14854 can make existing agent work move there, and later placement policy can choose the machine automatically.
