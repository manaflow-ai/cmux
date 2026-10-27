# Add Machine: one click from a host name to a working agent machine

Status: in progress, 2026-10-20. Branch `cmux/add-machine` into `feat-cmux-next`.

## The goal

The user types a host or picks a Tailscale peer. cmux then:

1. checks it can reach the host with key-only ssh;
2. installs cmux-tui on it (this carries acpmux as `cmux-tui acp`);
3. copies the harness profiles across;
4. starts the agent daemon;
5. registers the host as this machine's acpmux peer (and, only when asked, this machine on the
   host);
6. names the machine;
7. shows a health checklist that the user can re-run at any time.

Each step already exists somewhere: `remote.connect`, `remote.install`, `acpmux host setup`,
`harness doctor`, `remote_host/tailnet.rs`. They had no single flow and no single checklist. The
logic lives in Rust, so that the CLI, the app and agents all share it and it can be tested on
Linux. The app is one sheet on top of it.

## Surfaces

- `cmux-tui acp host enroll HOST [--name N] [--harness ID]... [--reverse] --json` runs the
  steps below, writing one JSON line per step and a final report.
- `cmux-tui acp host doctor NAME|HOST [--fix] [--reverse] --json` runs the checks alone. `--fix`
  re-runs only the steps whose checks failed.
- `cmux-tui acp host candidates --json [--probe]` lists Tailscale peers (online, OS, DNS name)
  and marks the ones that are already peers. `--probe` also tries key-only ssh, but only to the
  user's own online machines (same tailnet login, not tagged, not shared in), at most 32.
- App action `machine.add` ("Add Machine…", CLI `machine add`). It opens on the palette, on
  Settings > Machines, and on the Machines sidebar's add button. Per machine, `machine.doctor`
  ("Check Machine") opens the same checklist. `machine add HOST` from the CLI or MCP only opens
  the card with the host filled in; the enroll starts when the user presses Add (trust policy,
  conservative default until Leo decides).

## Step contract (one JSON line each)

```json
{"step":"reach","state":"ok|fail|skip|fixed","detail":"...","fix":"text for a person, or null"}
```

A failure the app acts on itself also carries `"reason"`: `install` sets `wrong-platform` (this build is for another OS or CPU), `peer_version_skew` (the peer's stale build needs a target-aware app install), or `not-this-program` (the host needs a binary only the app has); these make the app install its own build and run enroll again.

The steps run in this order, and a failed step stops the steps that depend on it:

| step | checks | fix |
|---|---|---|
| `reach` | `ssh -o BatchMode=yes HOST true`; failures classified as no route / ssh off / key rejected / host key changed | a sentence; never edits ssh config |
| `install` | the remote `cmux-tui --version` matches the local build | push this build (`host setup` push, never sudo) |
| `daemon` | the remote acp daemon answers `daemon status` | `host setup` config and launch (launchd on macOS, a detached start elsewhere) |
| `harness` | each chosen profile is on the host, hashes match after home-path rewrite, and is not group- or other-writable | copy, rewriting the local home prefix to the remote one, mode 600 |
| `peer` | `host ls` here lists NAME at `ssh://HOST` and it connects | `host add NAME ssh://HOST` |
| `peer-back` | only with `--reverse` (else `skip`): the host lists this machine and can reach it with key-only ssh | `host add` on the host; if the host cannot ssh back, `warn` with the reason and no fix (no keys are copied) |
| `identity` | the host's machine name matches NAME | the machine-identity lane's API |

`install` finds the acpmux the host already has: a standalone `~/.local/bin/acpmux`, a cmux app's
bundled one, or a cmux-tui (`~/.local/bin/cmux-tui`, the app's SSH install, or
`~/.cmux/bin/cmux-tui`) asked as `cmux-tui acp`. A cmux-tui of this build with no
`~/.local/bin/acpmux` only gets that link (no push, so a host of another OS works after the app
installed its build). A host with a cmux app, or whose daemon runs as `cmux-tui acp`, is cmux's:
nothing is pushed there and no standalone daemon is started beside it.

`peer-back` is opt-in. Two daemons that list each other relay one another's sessions both ways,
so the app and `doctor --fix` never pass `--reverse`. With it, this machine's address comes only
from its tailnet name (never `$SSH_CONNECTION`, which behind NAT or a jump host names another
machine); without a tailnet the step warns. A peer on the host that already points at this
machine by URL host (tailnet name, short name, host name, IP, or a bare name equal to a first label) counts, so no
duplicate is added.

The final line is `{"report":{"name":..,"host":..,"ok":bool,"steps":[..]}}`. A machine is
healthy when every step is `ok`, `fixed`, `warn` or `skip`. `peer-back` may be `warn` and the
machine still works from this side.

## Not in scope

- Copying ssh keys or changing ssh config, Tailscale ACLs or firewall rules. These are a person's
  call; the doctor names the fix.
- sudo or system services.
- Cloud machines, which already have their own create flow.
