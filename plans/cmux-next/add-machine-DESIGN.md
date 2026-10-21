# Add Machine: one click from a host name to a working agent machine

Status: in progress, 2026-10-20. Branch `cmux/add-machine` into `feat-cmux-next`.

## The goal

The user types a host or picks a Tailscale peer. cmux then:

1. checks it can reach the host with key-only ssh;
2. installs cmux-tui on it (this carries acpmux as `cmux-tui acp`);
3. copies the harness profiles across;
4. starts the agent daemon;
5. registers the acpmux peer in both directions;
6. names the machine;
7. shows a health checklist that the user can re-run at any time.

Each step already exists somewhere: `remote.connect`, `remote.install`, `acpmux host setup`,
`harness doctor`, `remote_host/tailnet.rs`. They had no single flow and no single checklist. The
logic lives in Rust, so that the CLI, the app and agents all share it and it can be tested on
Linux. The app is one sheet on top of it.

## Surfaces

- `cmux-tui acp host enroll HOST [--name N] [--harness ID]... [--no-reverse] --json` runs the
  steps below, writing one JSON line per step and a final report.
- `cmux-tui acp host doctor NAME|HOST [--fix] --json` runs the checks alone. `--fix` re-runs only
  the steps whose checks failed.
- `cmux-tui acp host candidates --json` lists Tailscale peers (online, OS, DNS name, ssh
  reachable) and marks the ones that are already peers.
- App action `machine.add` ("Add Machine…", CLI `machine add`). It opens on the palette, on
  Settings > Machines, and on the Machines sidebar's add button. Per machine, `machine.doctor`
  ("Check Machine") opens the same checklist.

## Step contract (one JSON line each)

```json
{"step":"reach","state":"ok|fail|skip|fixed","detail":"...","fix":"text for a person, or null"}
```

The steps run in this order, and a failed step stops the steps that depend on it:

| step | checks | fix |
|---|---|---|
| `reach` | `ssh -o BatchMode=yes HOST true`; failures classified as no route / ssh off / key rejected / host key changed | a sentence; never edits ssh config |
| `install` | the remote `cmux-tui --version` matches the local build | push this build (`host setup` push, never sudo) |
| `daemon` | the remote acp daemon answers `daemon status` | `host setup` config and launch (launchd on macOS, a detached start elsewhere) |
| `harness` | each chosen profile is on the host, hashes match after home-path rewrite, and is not group- or other-writable | copy, rewriting the local home prefix to the remote one, mode 600 |
| `peer` | `host ls` here lists NAME at `ssh://HOST` and it connects | `host add NAME ssh://HOST` |
| `peer-back` | the host lists this machine and can reach it with key-only ssh | `host add` on the host; if the host cannot ssh back, `warn` with the reason and no fix (no keys are copied) |
| `identity` | the host's machine name matches NAME | the machine-identity lane's API |

The final line is `{"report":{"name":..,"host":..,"ok":bool,"steps":[..]}}`. A machine is
healthy when every step is `ok`, `fixed` or `skip`. `peer-back` may be `warn` and the machine
still works from this side.

## Not in scope

- Copying ssh keys or changing ssh config, Tailscale ACLs or firewall rules. These are a person's
  call; the doctor names the fix.
- sudo or system services.
- Cloud machines, which already have their own create flow.
