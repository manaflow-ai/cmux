# Upgrading running Cloud machines

> **CLI note (2026-09-30):** the Mac-side `cmux vm push`, `vm pull` and exec verbs named
> below were removed in the Rust CLI cutover.

A cmux Cloud machine keeps the software its image baked for its whole life.
Nothing on the guest updates itself, so every change to guest software, the
daemon's command line, or the attach contract reaches only machines created
after the next bake unless it is shipped to running machines on purpose. This
doc is the contract that makes that shipping possible, the runbook for doing
it, and the plan for machines it cannot reach.

Read it before changing any of: `cmux-tui` (daemon, terminal host, remote
protocol, journal), `web/services/vms/images/devbox/` (the boot supervisor and
baked files), `web/scripts/build-devbox-freestyle.ts`, or any attach, open or
route code in `web/services/vms/` that reads `providerMetadata`.

## Why this exists

On 2026-09-24, [#14125](https://github.com/manaflow-ai/cmux/pull/14125) made attach refuse any machine whose row lacked
`cmuxTuiContract: "snapshot-v2"`, on the premise that no older machine
existed. 16 running machines of 10 users did. Their terminals stopped
connecting, and every team Mac retried each refused machine every 45 s: about
26,000 `502`s a day, each tagged `operator_fault`. Most of those machines
already ran a compatible daemon. Only a create-time database marker was
missing, and an in-place upgrade plus a one-row backfill restored them
(2026-09-28).

## What can reach a running machine

| Change | Reaches running machines? | How |
| --- | --- | --- |
| `cmux-tui` binary and `cmux-tui-hook` | Yes | `web/scripts/upgrade-fleet-cmux-tui.ts` (below) |
| Coding-agent hook entries | Yes | Same run: the pinned install command re-runs `cmux-tui agent hook install` |
| `cmux-devbox-boot`, systemd units, the daemon's argv and environment | No | Bake only. The supervisor that is running keeps its own copy |
| Baked packages, agent pins, desktop, `/etc/cmux/*` | No | Bake only |
| Create-time provider config: inline TLS rules (coderouter), VPC, firewall | No | Fixed at `vms.create`; the platform ignores later rules |
| `cloud_vms.provider_metadata` written at create | Only by a backfill | A reviewed SQL update, per machine, after verifying the guest |

So a change is updatable when it lives in the cmux-tui binary and stays
compatible with every supervisor, host and client still running. Anything
else is image-only: design it so old machines keep working without it.

## Rules for changes

### cmux-tui

- **The daemon's command line is owned by old supervisors.** Existing machines
  start `cmux-tui server start --session cloud --remote-ws <bind>
  --remote-ws-insecure-bind --remote-ws-trusted-carrier` from their baked
  `cmux-devbox-boot`, with the environment it exports. A new daemon must run
  correctly with exactly that argv and environment. Add flags only as optional
  with defaults that preserve today's behavior; never make a new flag or
  environment variable required, and never remove or rename one.
- **A new daemon adopts every live terminal host.** Each terminal runs in its
  own `__terminal-host` process (`cmux-tui-core/src/terminal_host_runtime.rs`),
  and a replacement daemon adopts them. The hosts keep running the build that
  spawned them, possibly for weeks, so the daemon must speak the terminal-host
  protocol (`spec/terminal-host.md`, `PROTOCOL_VERSION` 4) to every host
  build still in the fleet. Extend it only through negotiated flags; a version
  bump that refuses older hosts ends every running terminal on upgrade.
- **SIGTERM hands off.** The supervisor and the upgrade both stop the daemon
  with SIGTERM and start the new binary. SIGTERM must leave hosts alive and
  adoptable. Never kill hosts on shutdown, and never move them into a path
  where `systemctl restart cmux-tui-daemon` is the only restart (the unit's
  `KillMode=control-group` kills every host).
- **Journal and registry migrations are forward-only and one-way.** The new
  daemon must open every older on-disk schema. After it migrates, the old
  binary may not start, so a rollback is only safe before the new daemon runs.
  State this in the PR when a change migrates on-disk state.
- **Startup time is data-dependent.** A daemon replays its journal and adopts
  hosts before it listens; a 12 GB journal took about 3 minutes (2026-09-28).
  Nothing that waits for a daemon may assume seconds.
- **The remote protocol (`CMXR`, protocol 5) stays compatible** with released
  Mac clients, which the version gate already enforces.

### web (attach, open, create)

- **Never gate a running machine on a create-time marker alone.** A new marker
  or contract needs, in the same PR, either a backfill that sets it on every
  running machine that already qualifies, or a check against what the running
  daemon reports. Query the running fleet first:
  `select provider_metadata->>'cmuxTuiContract', count(*) from cloud_vms where destroyed_at is null and status = 'running' group by 1`.
- **A permanent refusal is not a `502`.** When a machine cannot be served and
  retrying cannot help, return a non-retryable status with a stable code and
  a user action (recreate), so clients stop polling and the UI can say what
  to do. `vm_cloud_service_unavailable` with `retryable: true` is for
  transient provider failures only.

### image (bake)

- Anything the daemon needs at start must work when absent: an old machine
  upgraded to the new binary will not have the new file, package or setting.

## Runbook: upgrade cmux-tui on running machines

The target is the cmux-tui build the default image bakes (the manifest's
`cmuxTuiCommit`), so an upgraded machine runs what a new machine runs.

1. **Inventory.** List running machines and their owners (read-only):
   `select provider_vm_id, provider_metadata->>'cmuxTuiContract', image_version from cloud_vms where destroyed_at is null and provider = 'freestyle' and status = 'running'`.
2. **Canary.** Run one machine you own, then attach to it from the Mac:

   ```bash
   cd web
   FREESTYLE_API_KEY=... bun scripts/upgrade-fleet-cmux-tui.ts --vm <vm-id>
   ```

3. **Fleet.** Internal machines, then external:
   `bun scripts/upgrade-fleet-cmux-tui.ts --vms-file <file>` (one id per line).
4. **Backfill** machines that were created before snapshot-v2 and now report
   `OK`, one reviewed statement, guarded so it cannot touch anything else:

   ```sql
   update cloud_vms
      set provider_metadata = provider_metadata || '{"cmuxTuiContract":"snapshot-v2"}'::jsonb,
          updated_at = now()
    where provider_vm_id = any($1)
      and destroyed_at is null
      and coalesce(provider_metadata->>'cmuxTuiContract', '') = ''
      and (provider_metadata ? 'networkIpv4' or provider_metadata ? 'networkIpv6')
   returning provider_vm_id;
   ```

   Save the rows first (`select row_to_json(v) ...`). Confirm the next attach
   for each machine returns 200 (Axiom `cmux-prod-otel-traces`, span
   `POST /api/vm/[id]/attach-endpoint`).

What the guest script (`web/scripts/cloud-vm/cmux-tui-upgrade.sh`) does per
machine: it runs detached as root from its own run directory
(`/var/lib/cmux-tui-upgrade/run-<time>-<commit>/`, with `result` and `log`),
and holds a per-machine lock, so a second run reports `SKIP busy`.

- `SKIP no-trusted-carrier`: the supervisor starts a pre-carrier daemon. A new
  binary would not make it attachable; the machine is image-only (below).
- `SKIP disk-free=<n>MB`, `SKIP no-daemon`, `SKIP daemon-not-listening`:
  nothing changed. A no-daemon machine usually crash-loops or has a full
  disk; inspect it.
- Otherwise it saves the running binary into the run directory, runs the
  pinned install command the bake uses (sha256-verified, atomic rename), sends
  the listening daemon SIGTERM, and waits up to 10 minutes for the
  supervisor's new daemon to listen. `OK upgraded` means the new daemon serves,
  no terminal host died, and the terminal count did not drop; either loss is
  `FAIL` instead, and `UNVERIFIED` means every host survived but a terminal
  count could not be read, so check that machine by hand.
- When the new daemon crashes or never listens, the script restores the saved
  binary and restarts the daemon. The new daemon may already have migrated
  on-disk state that the old binary cannot open, so the restore is trusted
  only when the old daemon serves again: `ROLLBACK` means it does,
  `FAIL rollback-daemon-unhealthy` means it does not and the machine needs a
  person (reinstall the target and debug it, or recreate the machine).

A connected Mac sees one daemon restart per upgraded machine: its link drops
and resumes; the terminals and their processes do not restart.

## When a machine cannot be upgraded

Some machines can never take a new contract in place: a supervisor too old for
the daemon's command line, create-time provider config that is missing, or a
guest too broken to exec into. Plan for this outcome in every contract change:

1. **Detect.** The inventory above plus the guest script's `SKIP` results name
   these machines; report them with owners before merging the change.
2. **Refuse clearly.** Attach returns a non-retryable status and code, and the
   client shows "Recreate this machine" instead of retrying.
3. **Keep the user's data reachable.** `cmux vm push`, `cmux vm pull` and exec
   do not use the attach route; do not gate them on the attach contract.
4. **Offer recreation.** A new machine from the current image; the user
   carries files across. Tell external owners before their machine stops
   working, not after.
5. **Stop the cost.** Idle machines that cannot be served still bill. Stop
   them with the owner's consent.
