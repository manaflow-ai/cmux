# cmux next: VM base image

Status: proposal, 2026-10-02 (VM image lead). Spec owner: the coordinator (decision V1 and A15 in the spec decisions; spec/team-vm.md; spec/cloud-and-automations.md). Only the coordinator edits the spec repo. Every number below was measured on Freestyle on 2026-10-02 by this lane unless marked "estimate" or UNVERIFIED. Raw data, scripts and SBOMs are in the lane's scratch directory, not in this repo.

Decided input: coderouter is in every VM by default (team VM, user cloud machines, automation hosts); a curated program set is baked in, improving on today's Cloud image (reproducible, pinned, fast boot, no secrets); the team VM runs a default Postgres for apps (database or schema per app, created by chief). This document proposes the package list, the build, the boot and identity contract, updates without a rebake, and the CI bake and smoke test.

## 1. Goals

- One image definition for every cmux Linux machine on Freestyle: user cloud machines, automation hosts, the team VM. Roles, not separate images, decide what runs.
- Reproducible: every input pinned by version and digest; an SBOM per image; two bakes from the same lock give the same package set and file hashes.
- Fast: a new machine answers on the daemon port in under 0.5 s p50 from `vms.create`.
- Small: no unrequested software; the root filesystem of the default image under 5 GB used; the memory image without gigabytes of stale page cache.
- Per-clone identity: two machines from one snapshot share no key, no machine id and no random state.
- Updates without a rebake: agents, `cmux`, coderouter, workerd and the other user-space programs update on running machines in seconds, atomically, with rollback.
- About 0 idle CPU: no polling loop in the image; an idle machine below 0.2 CPU-seconds per minute.
- No secrets in the image, checked by CI.
- A CI bake plus a smoke test gate every promotion.

## 2. Non-goals

- A second VM provider. The provider seam stays (`VMProvider`), but this image targets Freestyle's Ubuntu 24.04 guests.
- A desktop in the default image. The desktop becomes an optional role package (section 4.4).
- Kernel changes. Freestyle owns the guest kernel (6.1.102 today).

## 3. Today (baseline)

Today's image is the Cloud devbox: `web/services/vms/images/devbox/` (Dockerfile as reference recipe, `cmux-devbox-boot` supervisor, desktop layer) baked by `web/scripts/build-devbox-freestyle.ts` on the provider's `freestyle/ubuntu-sm` base, verified by `verify-devbox-image.ts`, derived into six sizes, and recorded in `web/services/vms/images/manifest.json`. Measured on the production default (md: 4 vCPU, 8 GiB, 32 GB; sm: 2 vCPU, 4 GiB, 16 GB):

| Metric | md | sm | Method |
| --- | --- | --- | --- |
| `vms.create` returns, p50 / p95 | 192 / 408 ms | 205 / 9,053 ms | host clock, n = 5 / 3; the 9 s value is one slow provider create |
| first exec answers, p50 / p95 | 288 / 490 ms | 317 / 9,163 ms | same runs |
| daemon ready (listening and bound to this instance id), p50 / p95 | 1,981 / 2,069 ms | 1,336 / 9,292 ms | `devboxDaemonReadyCondition`, about 0.4 s resolution |
| root filesystem used | 6.8 GB, 173k inodes | same layout | `df`, `du -x` |
| memory used at idle (plus page cache carried in the memory image) | 677 MiB (+ about 2.5 GB cache) | 629 MiB | `free -m` |
| idle CPU | 3.34 CPU-s/min (1.4% of the VM) | 2.61 CPU-s/min (2.2%) | `/proc` deltas over 300 s, 5 min after create |
| process creations at idle | 461 per minute | 462 per minute | `/proc/stat processes` delta |
| SBOM components | 42,456 (+768 npm packages with the JavaScript cataloger) | | syft 1.54.0, 46 s |

Where the idle CPU goes (md, CPU-s/min including children): boot supervisor 2.01 (60%: a 1 s loop with two metadata-service `curl` calls, 354 forks per minute), desktop supervisor 0.58 (re-runs `start-vnc.sh` every 30 s), terminal host 0.13 (50 wakeups/s), containerd 0.08 (Docker runs with zero images), prompt sync 0.05 (Python, 30 s fetch), resource reporter (Python, an HTTPS POST every 30 s).

Pinning audit of today's recipe:

| Input | State |
| --- | --- |
| provider base `freestyle/ubuntu-sm` (node under nvm, bun, uv, Docker, a provider Python, an unrequested third-party agent package of 394 MiB, a 345 MiB npm copy of bun, TypeScript tools) | floating slug |
| 743 apt packages (devtools, media, desktop) | floating archive, no versions |
| gh (apt repo, keyring fetched at bake) | floating |
| Chrome (`google-chrome-stable_current` .deb) | floating, no digest; adds a Google apt repo and a cron job |
| cua-driver 0.23.2 | version pinned, installer unverified |
| ble.sh `nightly` | floating, no digest |
| coding agents (npm, exact top-level versions) | dependencies float, install scripts run unverified |
| Ghostty .deb, cmux-tui, guest CLI | pinned and sha256-verified |

Other findings: `/etc/machine-id`, `boot_id` and the systemd random seed are equal on every clone; `/var/cache/apt` keeps 291 MiB of downloaded packages; no secret was found in the image (SSH host keys are re-keyed per clone; the model-plane file holds only the placeholder key, and the TLS edge injects the route token). `/dev/urandom` output already differed between clones before the supervisor's reseed on kernel 6.1.102, but the reseed stays (section 6).

Shipping to running machines is limited today (docs/cloud-guest-upgrades.md): only the cmux-tui binary can be upgraded in place; the supervisor, units, packages and agent pins change only through a rebake (about 4 min bake + 3 min verify + size derivation) and reach only new machines.

## 4. Design

### 4.1 Three layers

| Layer | Contents | Changes | How it reaches machines |
| --- | --- | --- | --- |
| L0 provider base | Freestyle's Ubuntu 24.04 guest (kernel, provider agent, network config) | provider releases | a rebake from a recorded base fingerprint (below) |
| L1 cmux OS | apt packages from a dated Ubuntu snapshot mirror, the work user, systemd units, the one boot unit (`cmux host`), Docker engine, PostgreSQL 17 binaries (disabled unless the role needs them), minimal tools | rarely (security updates, a new package) | rebake; machines get it at recreate |
| L2 cmux store | content-addressed user-space packages under `/opt/cmux/store/<sha256>/`: `cmux`, coderouter, workerd, coding agents, toolchains not in L1, JuiceFS, the telemetry agent | often (agents weekly or daily) | baked into the snapshot and updated in place by a signed channel manifest (section 4.5) |

L0 is pinned by fingerprint, not by slug: the bake records the base snapshot id the provider resolved, the kernel release, and the sha256 of the base's package list. A bake refuses to run when the fingerprint differs from `images/cmux-vm/inputs.lock.json` unless the lock is updated in the same change (a base change is then a reviewed diff).

Unrequested base software is removed in L1 (the third-party agent package, the npm copy of bun, the TypeScript tools; together about 0.75 GiB). The provider's own Python (`/opt/freestyle/python`, 1.5 GiB) stays until we prove the provider agent does not need it (UNVERIFIED); cmux scripts stop depending on it.

### 4.2 Package list (V1 "package list pending")

Default role set: every machine. Sizes are installed sizes on the guest.

| Program | Role | Source and verification | Installed | Idle |
| --- | --- | --- | --- | --- |
| `cmux` (Rust: session host, link, automations host, team host, updater, reconciler; today `cmux-tui` + hook) | all | files.cmux.com by commit, sha256 + build attestation | 45 MB | daemon 0.01 CPU-s/min, 51 MB PSS; terminal host 0.12 to 0.14 CPU-s/min |
| coderouter CLI (`coderouter`, `cr`) configured for the VM's edge alias | all | coderouter release, sha256 (manifest unsigned today) | 7 MB | none (CLI) |
| Claude Code (native binary) | all | vendor release manifest sha256 + its signature | 234 MB | none until run |
| Codex (musl release tarball) | all | vendor release, sha256 + Sigstore bundle | 263 MB | none until run |
| OpenCode (linux-x64 package) | all | npm integrity | 186 MB | none until run |
| pi | all | npm (ships a shrinkwrap), integrity + provenance | 437 MB | none until run |
| Node 24 LTS, Bun, Python 3.12 + uv | all | upstream releases, checksums + signatures | 208 + 76 + 104 + 47 MB | none |
| git, gh, ripgrep, jq, fd, fzf, sqlite3, tmux, build-essential, bubblewrap, curl, rsync, vim, nano | all | apt snapshot mirror; gh release tarball | (in L1) | none |
| Docker engine | all, socket-activated | apt (Ubuntu archive snapshot) | about 400 MiB | 0 until the first `docker` call (today dockerd + containerd: 116 MB PSS, 0.06 CPU-s/min) |
| telemetry agent: OpenTelemetry Collector built with the collector builder (OTLP, filelog, journald, hostmetrics receivers; batch, memory_limiter; otlphttp exporter) | all | our CI build, sha256 | 42 MB | 34 MiB RSS; 0.32% of a core with 10 s host metrics (1 min interval proposed) |
| WireGuard | all | built into the guest kernel; `wg` present | 0 | 0 (the overlay runs in-process in `cmux`, spec sync-and-transport section 6) |
| workerd (pinned) | automation host, team | upstream release, digest + npm provenance | 129 MB | started on demand by the automations host |
| PostgreSQL 17 | team and servers (binaries in L1; no cluster in the image; section 5) | PGDG apt, key fingerprint checked; versions pinned | 68 MB | 25.6 MB PSS, 0.012 CPU-s/min |
| JuiceFS | team | upstream release, checksums | 120 MB | mount only on the team VM (UNVERIFIED idle) |
| desktop (VNC session, Chrome, Ghostty, window manager, cua-driver) | optional role package | as today, plus digests for Chrome and cua-driver | about 1 GB | 92 MB PSS, 0.03 CPU-s/min while running; not started unless asked |
| chief | not in the base (section 9, decision) | | | |

Not shipped: mise (no longer needed; the base toolchain plus the store cover it), Nix (section 8), the unrequested base packages above.

### 4.3 Roles

A machine's role set is chosen by the control plane at create and written with the instance binding (section 4.6): `interactive` (default), `automation`, `team`, plus optional `desktop`. `cmux host` starts only the units of the active roles. Inactive role packages cost disk, not memory or CPU. One image keeps one bake, one SBOM and one size ladder.

Measured variants (all from `freestyle/ubuntu-sm`, 2 vCPU, 4 GiB, 16 GB; 5 clones each; idle over 300 s):

| Variant | Bake time | Root fs used | create to first exec p50 / p95 | create to daemon listening p50 / p95 | Idle CPU-s/min | Memory used |
| --- | --- | --- | --- | --- | --- | --- |
| today (production md) | about 4 min | 6.8 GB | 288 / 490 ms | 1,981 / 2,069 ms | 3.34 | 677 MiB |
| lean (all roles' binaries, no desktop, no polling supervisor) | 87 s | 5.85 GB | 150 / 221 ms | 486 / 569 ms | 0.158 | 466 MB |
| team (lean + Postgres running) | +57 s | 6.10 GB | 498 / 1,376 ms | 770 / 2,948 ms | 0.234 | 502 MB |
| full (lean + desktop running) | +168 s | 6.88 GB | 168 / 240 ms | 514 / 661 ms | 0.728 | 565 MB |

The lean bake did not yet strip the unrequested base packages or socket-activate Docker; both are expected to cut about 0.75 GiB of disk and about 0.06 CPU-s/min (estimate). A team clone's `vms.create` takes 435 to 491 ms instead of 98 to 254 ms when Postgres runs at snapshot time (cause UNVERIFIED); section 4.7 avoids it.

Recommendation: one image, `lean` contents, roles at create, desktop off by default.

### 4.4 Desktop

Today every machine runs the desktop (VNC, window manager, dock, noVNC) and its supervisor re-runs every 30 s. Proposal: the desktop is a role. `cmux vm open <m>:desktop` (and the Displays row) asks the machine's session host to start it; the session host owns headless displays (spec/computer-use.md), so the CUA host and agent GUI work use the same path. Its supervisor is event-driven (systemd restarts on exit; no 30 s re-run). Cost when on: 92 MB PSS, 0.03 CPU-s/min.

### 4.5 Updates without a rebake (the cmux store)

- Layout: `/opt/cmux/store/<sha256>/` holds one immutable package (read-only after unpack). `/opt/cmux/profiles/<generation>/bin` is a symlink farm into the store. `/opt/cmux/current` points at one profile; it changes with one `rename(2)`. `PATH` and units refer only to `/opt/cmux/current/bin`.
- Channel manifest: JSON listing every package (name, version, URL, sha256, size, roles), a sequence number, an expiry and the minimum `cmux` version; signed (minisign or an equivalent detached signature), with two public keys baked (current and next, for rotation). Files are mirrored to files.cmux.com by sha256 so a GitHub outage or rate limit does not block updates.
- Updater: a role of the `cmux` binary (`cmux host update`), not a script. It refuses a bad signature, an expired manifest, or a sequence lower than the last applied one; downloads in parallel with streaming hashes and size limits; unpacks safely; builds the profile; flips; keeps the last N profiles; takes a lock so only one apply runs.
- Triggers, no timer: at resume and at boot (one check), and when the control plane pushes "channel changed" over the link. A paused machine updates when it next wakes.
- Restart policy per package: CLIs need none (a running process keeps its open binary; new invocations get the new one); long-running services (`cmux` session host, workerd, the telemetry agent) restart through their handoff contracts (the session host keeps terminal hosts alive across SIGTERM, docs/cloud-guest-upgrades.md).
- Rollback: flip `current` back. A machine reports its applied generation to the control plane, which shows it and can pin a machine or a team to a generation.

Measured prototype (2 vCPU guest; update Codex 0.154.0 to 0.160.0 and add coderouter): apply p50 3.3 s (n = 4; download 1.3 to 1.5 s, unpack 1.8 to 2.3 s, signature check under 10 ms, flip under 1 ms); rollback p50 70 ms (n = 9); re-apply from the store 75 ms; boot-time no-op 109 ms. A running `codex app-server` kept serving across the flip and after its store folder was deleted; an open shell ran the new version on the next invocation; a tampered manifest and a downgrade were refused. Compared with today: a rebake plus verify plus derive is more than 7 minutes and reaches only new machines.

What still needs a rebake: L1 (apt packages, units, the boot unit's command line, kernel-adjacent settings) and L0. The boot unit's command line is frozen as `cmux host run`, so the supervisor's behavior moves with the `cmux` binary in the store, and old units never own new logic.

### 4.6 Boot and per-clone identity

(Filled from the clone-identity prototype; section 6.)

### 4.7 Fast boot

- Keep the memory-snapshot model: the session host's warm template terminal and parked services ride in the snapshot.
- Start the session host directly from `cmux host` at bind, not through `systemd-run`: on a resumed clone systemd waits about 1.8 s before it starts the first transient unit (spawn to listen 2,079 ms through `systemd-run` vs 260 ms with a direct spawn).
- Drop the page cache before the snapshot (`sync; echo 3 > /proc/sys/vm/drop_caches`) and remove `/var/cache/apt/archives` and the npm cache (about 1 GB in the lean bake) so the memory and disk images stay small.
- Postgres (team role) is stopped at snapshot time and started at bind, so `vms.create` stays fast (section 5); the cold start cost after bind is UNVERIFIED.
- Systemd timers stay parked in the snapshot and are re-armed off the critical path at bind (as today), but the daily apt, man-db and motd timers are removed, not re-armed: updates come from the store and from rebakes.

### 4.8 About 0 idle CPU

Budget for an idle machine (no client attached, no agent running): total under 0.2 CPU-s/min, no process creation while idle, no periodic network traffic except the provider fabric announce if it proves necessary.

| Source today | Proposal |
| --- | --- |
| boot supervisor, 1 s metadata poll (2.01 CPU-s/min) | event-driven bind (section 4.6); no loop |
| desktop supervisor, 30 s re-run (0.58) | desktop is a role, systemd restarts on exit |
| network announce, `arping` every 30 s | keep only if the fabric drops idle machines (UNVERIFIED); then run it from the `cmux` process on a one-shot deadline after the last outbound frame, not on a fixed tick |
| prompt sync, Python, 30 s fetch | the session host receives the machine's name from the control plane over the link (event) |
| resource reporter, Python, HTTPS POST every 30 s | the session host serves `machine-stats` on request and streams it only while a client watches |
| Docker running from boot (0.06, 116 MB) | `docker.socket` activation |
| terminal host, 50 wakeups/s (0.13) | a cmux-tui bug to fix in the daemon (an idle terminal should not wake); tracked for the session host owner |
| telemetry agent | 1 min host metrics; logs via journald cursor (event) |

### 4.9 No secrets in the image

- Model traffic: the guest dials the edge alias with a placeholder key; the provider's TLS edge injects the machine's route token (`web/services/coderouter/vmGuestEnv.ts`). The coderouter CLI in the image is configured for the same alias, so `cr` works with no login and no token on disk.
- Telemetry: the agent exports OTLP to the local `cmux` process, which forwards on its authenticated link; no ingest token in the guest.
- Per-machine secrets are created after bind, never at bake: SSH host keys, the daemon's Noise identity, the WireGuard key, `machine-id`, the random seed.
- CI check on every bake: a secret scanner over the root filesystem (paths and pattern kinds only), plus explicit refusals: no `crt_`/`crk_` grammar in `/etc/cmux`, no `.npmrc` auth, no git credentials, no `authorized_keys`, shell histories equal the seed, `/tmp` empty, journal empty.

### 4.10 Reproducible build and SBOM

- `images/cmux-vm/inputs.lock.json`: the L0 fingerprint, the apt snapshot timestamp (`https://snapshot.ubuntu.com/ubuntu/<timestamp>/`, every suite), every PGDG and third-party apt package at an exact version, and every store package by URL and sha256. A bake reads only the lock.
- Measured: two lean bakes from scratch, two minutes apart: 28,491 SBOM components each with 0 name or version differences; identical dpkg (417) and npm (634) lists; 99,776 file hashes with 1 difference (`/etc/cmux/image-stamp`, by design). Not yet proven across days (floating base slug, npm transitive ranges, install-script downloads, PGDG dependencies outside the snapshot mirror).
- Fixes for those gaps: L0 fingerprint (4.1); agents from vendor release binaries instead of npm where available (Claude Code, Codex); npm packages installed with `--ignore-scripts` from a lock where possible, else listed as an accepted risk; PGDG dependencies pinned by version (its archive keeps old versions).
- SBOM: syft over the root filesystem with the JavaScript cataloger on (the default directory scan misses npm packages), CycloneDX JSON, merged with the store manifest (native binaries such as Codex, Claude Code and `cmux` show no inner components in a filesystem scan, so their own SBOMs, where vendors publish them, are attached by digest). Stored next to the manifest entry and the channel manifest, signed with the same key.
- After install, apt sources point back at the live archive so a user's `apt install` gets current security updates; the baked packages stay as locked. Alternative: keep the dated mirror (fully frozen machine). Recommendation: live archive for users, dated mirror for the bake.

### 4.11 CI bake and smoke test

- Workflow `cloud-vm-image-bake.yml` (dispatch, and on changes to `images/cmux-vm/**` on the cmux-next branch): bakes on the staging Freestyle account into `cmuxnp-…`-named prototype snapshots for branches and `cmux-vm-<date>-<sha>` for promotions; derives the size ladder (about 30 s with parallel rows, as today).
- Smoke (gate before any manifest change), on two clones of each new snapshot: daemon listening under the latency budget; bound instance id equals the provider's; every identity item differs between the two clones (machine-id, SSH host keys, daemon identity, WireGuard key, first `/dev/urandom` bytes); every store package runs (`--version`); `cr capabilities --json`; the agents' first interactive launch reaches the composer (the tmux screen check today's verifier does); idle CPU over 120 s under the budget and zero process creations; the secret scan; the SBOM generated and signed; Postgres reachable on the team role; the updater applies and rolls back a test manifest.
- Promotion stays a reviewed change to the image manifest; rollback is its revert (as today).

## 5. Team VM and servers

The team VM and self-hosted servers run the same "VM software" (spec SV1 to SV3; owned by the cmux server lane, plans/cmux-next/server.md). This image bakes what both need and does not decide the app-server or Postgres layout:

- Baked: PostgreSQL 17 server and client binaries (PGDG, pinned), JuiceFS, workerd, the `cmux` binary with its server, team-host and automations-host roles, coderouter. All units are disabled in the image; the `team` role (and `cmux server up` on a server) enables what the server lane's design says.
- Not baked: a cluster, a port, roles, `pg_hba` rules or app databases. The server software creates them at first start, after bind, so no two machines share a cluster identity or a password, and the server lane owns their layout (unique port per install, local-only listener, per-app roles; SV2).
- Image facts the server lane needs: the private network interface is attached after resume, so an address list frozen at snapshot time does not include it (a listener that must reach the team network binds at start, not at bake); a cluster running in the snapshot slowed `vms.create` from 98 to 254 ms to 435 to 491 ms (n = 10), so the cluster is stopped at snapshot time and started at bind; after resume a running cluster answered a peer-auth `select 1` in 112 to 124 ms (n = 10); the cluster at idle used 25.6 MB PSS and 0.012 CPU-s/min.
- One store for both: a server installed with the curl command and a VM use the same store layout (section 4.5), the same channel manifest and the same updater, so "VM software" is one package set with one SBOM.
- Database files stay on local disk, never on the JuiceFS tier (a database on an object-storage filesystem pays a remote round trip per fsync); durability is the server lane's backup design.

## 6. Boot and per-clone identity

(Filled from the clone-identity prototype.)

## 7. Ownership

| Entity | Owner | Others |
| --- | --- | --- |
| Image definition (lock, recipe, units) | the image owner in the repo (this file and `images/cmux-vm/`) | CI reads it |
| Image manifest entry, defaults per kind and size | the promotion change (reviewed) | the control plane reads it at create |
| Channel manifest (store package set per channel) | the control plane (signed by CI) | machines pull it on push or resume |
| Applied store generation on a machine | that machine's `cmux host` | reported to the control plane, shown in UI |
| Instance binding and role set | the control plane at create | `cmux host` applies it |
| Per-machine keys and identity | the machine (generated after bind) | public parts registered with the control plane |

## 8. Alternatives considered

- Nix for the store: rejected for now. A closure of 18 packages was 3,350 MiB (about 1.6x the plain packages); nixpkgs lags upstream releases by days (agent updates must ship the same day) and lacks workerd; flake locks pin inputs, not the bytes of prebuilt upstream binaries, which our sha256 pins already fix. Guests now have IPv4 egress, so the old IPv6-only installer hang is gone.
- Bake per size and kind (today: 6 sizes x 2 kinds from one bake): kept; derivation is fast (about 30 s) and avoids a resize at create.
- Separate images per role: rejected; one image keeps one SBOM, one smoke and one ladder.

## 9. Strongest objections

1. "A store updater is a live software-update channel into every customer machine; a compromised signing key owns the fleet." Answer: signatures with keys held in KMS and used only by CI on protected branches; two baked public keys for rotation; sequence and expiry checks against replay and freeze attacks; per-team pinning; an audit record per apply; the same trust as today's in-place cmux-tui upgrade, with more checks.
2. "Event-driven bind can miss a clone made outside our driver." Answer: section 6 keeps a fallback signal and a check at every link connect.
3. "Postgres in every image costs disk for roles that never use it." Answer: 68 MB, disabled unit; one image is cheaper to bake, test and audit than two.

## 10. Surfaces

| Op | CLI | MCP | Palette | Notes |
| --- | --- | --- | --- | --- |
| `vm.image.show {machine}` (image id, store generation, channel, SBOM link) | `cmux vm image show <m> --json` | yes | "Show Machine Image" | read |
| `vm.image.update {machine, generation?}` | `cmux vm image update <m> [--generation G] --wait` | yes | "Update Machine Software" | idempotency key; waits until applied |
| `vm.image.rollback {machine, generation}` | `cmux vm image rollback <m> --generation G --wait` | yes | "Roll Back Machine Software" | |
| `vm.image.sbom {image}` | `cmux vm image sbom <image> --json` | yes | exempt (no UI value beyond show) | |

Settings: `cloud.machines.channel` (`stable` default, `beta`), `cloud.machines.desktop` (off by default), `cloud.machines.autoUpdate` (on; off pins the generation). Team policy can enforce each (spec/enterprise.md). Right-click on a machine row: Update Machine Software, Show Machine Image.

## 11. Steps

1. `images/cmux-vm/` with the lock, the L1 recipe and the smoke; bake on staging; numbers against section 3.
2. `cmux host` bind and supervisor role in the Rust binary (replaces `cmux-devbox-boot`), with the clone tests.
3. Store updater role, channel manifest signing in CI, files.cmux.com mirror.
4. Team role and servers: enable what the server lane specifies; JuiceFS after the storage spike; automations host.
5. Promote as the cmux-next default; today's devbox stays for the current app until cmux-next ships.

## 12. Decisions needed

Listed in the lane report to the coordinator.
