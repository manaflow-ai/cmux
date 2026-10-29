# Upgrading running Cloud machines

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
| `cmux-tui` binary, `cmux-tui-hook`, and the state-mount helper | Yes | `web/scripts/upgrade-fleet-cmux-tui.ts` (below) |
| Coding-agent hook entries | Yes | Same run: the pinned install command re-runs `cmux-tui agent hook install` |
| The guest DNS fallback (`cmux-dns` and its units) | Yes | `web/scripts/install-fleet-dns-fallback.ts` (below) |
| `cmux-devbox-boot`, systemd units, the daemon's argv and environment | No | Bake only. The supervisor that is running keeps its own copy |
| Baked packages, agent pins, desktop, `/etc/cmux/*` | No (agent pins: only on machines opted into `agentUpdates: "latest"`) | Bake only; opted-in machines update their coding agents on attach (`web/services/vms/guestAgentUpdates.ts`) |
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
Machines created by fork, restore or a template boot the source's snapshot,
not the default image, so they keep its older cmux-tui and belong in the
inventory like any other running machine.

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
and holds a per-machine lock, so a second run reports `SKIP busy`. Before it
touches the daemon it atomically installs the current state-mount helper and
runs its `ensure` path, so a running machine receives the bounded state-image
growth fix even when its daemon is crash-looping. If the daemon upgrade needs
to roll back, the previous helper is restored with the binary.

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

## Runbook: install the DNS fallback on running machines

Machines baked before the DNS fallback (`web/services/vms/images/devbox/README.md`,
"DNS fallback") resolve straight through the platform resolver, which
intermittently answers SERVFAIL or nothing for every name
([#26640](https://github.com/manaflow-ai/cmux/issues/26640)). Users see this as
lost internet. The runner installs the same files with the same install and
check commands the bake runs, so a fixed machine matches a new one.

It changes customer machines as root: it adds a DNS service and points
resolv.conf at it. Do not run it on the fleet before these steps.

1. **Tell owners.** Say what changes (a local DNS service, resolv.conf), why,
   and how to opt out. Do it before the first customer machine.
2. **Inventory.** The running Freestyle machines, as in the cmux-tui runbook above.
3. **Canary.** One machine you own, then one customer machine whose owner agreed:

   ```bash
   cd web
   FREESTYLE_API_KEY=... bun scripts/install-fleet-dns-fallback.ts --vm <vm-id>
   ```

   Then on that machine, `getent ahostsv4 github.com` works and
   `head -1 /etc/resolv.conf` prints `# cmux-dns`. Watch both for a day,
   including a pause and resume.
4. **Fleet.** `bun scripts/install-fleet-dns-fallback.ts --vms-file <file>`
   (one id per line). It runs 8 machines at a time, each in about 5 seconds, and
   stops after a batch with a `FAIL` or `ERR`. It lists the machines it did not
   start; read the failure, then run again (machines already done report
   `SKIP current`).

Results, one line per machine:

- `OK installed`: the stub answers and resolv.conf points at it.
- `SKIP current`: the same stub and units are already installed and pass the check.
- `SKIP no-systemd`: not a devbox guest (a container image). Nothing changed.
- `SKIP custom-resolv-conf`: resolv.conf is a link, or the platform did not
  write it (the user, a VPN or Tailscale owns DNS). Nothing changed.
- `SKIP busy`: another run holds the machine's lock (`flock` on
  `/run/cmux-dns-fleet.lock`; the kernel frees it when that run exits or dies).
- `SKIP no-flock`: the guest has no `flock`. Nothing changed.
- `SKIP not-running <state>`: the runner reads the state with a plain GET
  first and leaves a paused or stopped machine asleep. Run it again when the
  machine runs.
- `FAIL <reason> (...)`: the install or its check failed. The runner saved the
  files, the unit states and resolv.conf first, put them back, and checked
  that it did. `rolled back`: nothing was there before, and nothing is now.
  `restored the previous fallback`: an older stub was there and runs again.
  `left the installed fallback in place`: this version was already installed;
  nothing was rewritten or restarted. `rollback incomplete`: the check after
  the restore failed; look at the machine by hand.
  During a platform resolver outage, a stub that just started has no cached
  answers, and it fails a cold miss closed while TLS steering is active (the
  devbox README). Its install check then fails and the runner puts back what
  the machine had. Run it again after the outage.
- `FAIL timeout ...`: the exec ran out of time (180 s) before the result. Run
  that machine again; a second run finishes or rolls back.
- `ERR`: a provider call failed. Nothing is known about the machine.

Terminals and their processes keep running. The platform rewrites resolv.conf
on every TLS rule change and on resume; the installed guard re-points it within
a second, as on a new machine. To take the fallback off, run the same command
with `--remove` (`OK removed`, or `FAIL remove incomplete` when something is
left).

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
