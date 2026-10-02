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

Other findings: `/etc/machine-id`, `boot_id` and the systemd random seed are equal on every clone; `/var/cache/apt` keeps 291 MiB of downloaded packages; no secret was found in the image (SSH host keys are re-keyed per clone; the model-plane file holds only the placeholder key, and the TLS edge injects the route token). `/dev/urandom` output differed between clones of an old snapshot even before the supervisor's reseed, but forks made seconds after a snapshot shared it (section 6.1), so the reseed stays.

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
| coderouter CLI (`coderouter`, `cr`) configured for the VM's edge alias | all | coderouter release by sha256; today a glibc build with an unsigned checksum file and no declared license (ask: a static musl build and a signed manifest) | 7 MB | none (CLI) |
| Claude Code (native binary) | all | vendor release manifest sha256 + its signature | 234 MB | none until run |
| Codex (musl release tarball) | all | vendor release, sha256 + Sigstore bundle | 263 MB | none until run |
| OpenCode (linux-x64 package) | all | npm integrity | 186 MB | none until run |
| pi (1.0.0 is current; today's pin is 0.85.1) | all | npm (ships a shrinkwrap), integrity + provenance; no single-file release, so CI packs one tarball per version into the store | 437 MB | none until run |
| Node 24 LTS, Bun, Python 3.12 + uv | all | upstream releases, checksums + signatures | 208 + 76 + 104 + 47 MB | none |
| git, gh, ripgrep, jq, fd, fzf, sqlite3, tmux, build-essential, bubblewrap, fuse3, acl, curl, rsync, vim, nano | all | apt snapshot mirror; gh release tarball | (in L1) | none |
| Docker engine | all, socket-activated | apt (Ubuntu archive snapshot) | about 400 MiB | 0 until the first `docker` call (today dockerd + containerd: 116 MB PSS, 0.06 CPU-s/min) |
| telemetry agent: OpenTelemetry Collector built with the collector builder (OTLP, filelog, journald, hostmetrics receivers; batch, memory_limiter; otlphttp exporter) | all | our CI build, sha256 | 42 MB | 34 MiB RSS; 0.32% of a core with 10 s host metrics (1 min interval proposed) |
| WireGuard | all | built into the guest kernel; `wg` present | 0 | 0 (the overlay runs in-process in `cmux`, spec sync-and-transport section 6) |
| workerd (pinned) | automation host, team | upstream release, digest + npm provenance | 129 MB | started on demand by the automations host |
| PostgreSQL 17 | team and servers (binaries in L1; no cluster in the image; section 5) | PGDG apt, key fingerprint checked; versions pinned | 68 MB | 25.6 MB PSS, 0.012 CPU-s/min |
| JuiceFS | team | upstream release, checksums | 120 MB | mount only on the team VM (UNVERIFIED idle) |
| desktop (VNC session, Chrome, Ghostty, window manager, cua-driver) | optional role package | as today, plus digests for Chrome and cua-driver | about 1 GB | 92 MB PSS, 0.03 CPU-s/min while running; not started unless asked |
| chief | not in the base (section 12, decision) | | | |

Not shipped: mise (no longer needed; the base toolchain plus the store cover it), Nix (section 8), the unrequested base packages above.

### 4.3 Roles

A machine's role set is chosen by the control plane at create and written with the instance binding (section 4.6): `interactive` (default), `automation`, `team`, plus optional `desktop`. `cmux host` starts only the units of the active roles. Inactive role packages cost disk, not memory or CPU. One image keeps one bake, one SBOM and one size ladder.

Measured variants (all from `freestyle/ubuntu-sm`, 2 vCPU, 4 GiB, 16 GB; 5 clones each; idle over 300 s):

| Variant | Bake time | Root fs used | create to first exec p50 / p95 | create to daemon listening p50 / p95 | Idle CPU-s/min | Memory used |
| --- | --- | --- | --- | --- | --- | --- |
| today (production md, 4 vCPU; sm daemon-ready p50 1,336 ms, n = 3) | about 4 min | 6.8 GB | 288 / 490 ms | 1,981 / 2,069 ms | 3.34 | 677 MiB |
| lean (all roles' binaries, no desktop; no supervisor: the measurement spawned the daemon directly) | 87 s | 5.85 GB | 150 / 221 ms | 486 / 569 ms | 0.158 | 466 MB |
| team (lean + Postgres running) | +57 s | 6.10 GB | 498 / 1,376 ms | 770 / 2,948 ms | 0.234 | 502 MB |
| full (lean + desktop running) | +168 s | 6.88 GB | 168 / 240 ms | 514 / 661 ms | 0.728 | 565 MB |
| **proposed** (lean, base extras stripped, store, Docker socket-activated, event-driven bind agent, page cache dropped) | 66 s | 4.88 GB, 111k inodes | 165 / 256 ms | 584 / 648 ms | 0.144 (5 process creations/min) | 313 MB (78 MB page cache) |

The proposed row is one integrated prototype of sections 4.5 to 6 (bind agent in Python for the prototype; the real one is Rust inside `cmux`). Against today it cuts disk by 1.9 GB, inodes by 36%, idle CPU by 96% (3.34 to 0.144 CPU-s/min), process creations from 461 to 5 per minute, and idle memory by more than half; the bind agent wakes 21 to 27 ms before `vms.create` returns. Stripping the base's npm globals alone saved 1.72 GB: the unrequested agent package, the npm copy of bun and TypeScript tools (0.71 GB) and the base's floating copies of three coding agents (1.01 GB), which the store replaces. Its daemon listens about 100 ms later than the lean row: spawn to listening is about 430 ms on a clone versus 260 ms with a warm page cache, most likely because the page cache was dropped before the snapshot (no A/B yet; section 4.7). A team clone's `vms.create` takes 435 to 491 ms instead of 98 to 254 ms when Postgres runs at snapshot time (cause UNVERIFIED); section 4.7 avoids it.

Recommendation: one image, `proposed` contents, roles at create, desktop off by default. The 0.5 s daemon-listening goal is not met yet (584 ms p50); the page-cache step in section 4.7 is the first lever, then the daemon's own start path.

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

See section 6.

### 4.7 Fast boot

- Keep the memory-snapshot model: the session host's warm template terminal and parked services ride in the snapshot.
- Start the session host directly from `cmux host` at bind, not through `systemd-run`: on a resumed clone systemd waits about 1.8 s before it starts the first transient unit (spawn to listen 2,079 ms through `systemd-run` vs 260 ms with a direct spawn).
- Remove `/var/cache/apt/archives` and the npm cache (about 1 GB in the lean bake) and the base's unrequested packages (1.7 GB) so the disk image stays small.
- Page cache: dropping it before the snapshot cut the idle memory image to 78 MB of cache but likely cost about 170 ms of daemon start on each clone. Proposal: drop the cache, then read back exactly the files the bind path needs (the `cmux` binary, its libraries, the shell and the warm terminal's files) before the snapshot, so the image stays small and the start stays warm. Needs an A/B measurement (UNVERIFIED).
- Postgres (team role) is stopped at snapshot time and started at bind, so `vms.create` stays fast (section 5); the cold start cost after bind is UNVERIFIED.
- Systemd timers stay parked in the snapshot and are re-armed off the critical path at bind (as today), but the daily apt, man-db and motd timers are removed, not re-armed: updates come from the store and from rebakes.

### 4.8 About 0 idle CPU

Budget for an idle machine (no client attached, no agent running): total under 0.2 CPU-s/min, no process creation while idle, no periodic network traffic except the provider fabric announce if it proves necessary.

| Source today | Proposal |
| --- | --- |
| boot supervisor, 1 s metadata poll (2.01 CPU-s/min; 18.5 CPU-s/min while parked at 50 ms) | event-driven bind (section 6.2): 0.00 CPU-s/min, under 2 wakeups per minute |
| desktop supervisor, 30 s re-run (0.58) | desktop is a role, systemd restarts on exit |
| network announce, `arping` every 30 s | once at bind and on each resume signal (section 6.4) |
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

- Workflow `cloud-vm-image-bake.yml` (dispatch, and on changes to `images/cmux-vm/**` on the cmux-next branch). Snapshots are account-scoped, so a promotion bakes on the account that serves production (`cmux-vm-<date>-<sha>`), as today; branch bakes use `cmuxnp-…` names and are deleted by id after the smoke. A separate non-production Freestyle account would isolate branch bakes (decision in the lane report). The bake derives the size ladder (about 30 s with parallel rows, as today) and takes about 1 minute (66 s for the prototype, versus about 4 minutes today).
- Smoke (gate before any manifest change), on two clones of each new snapshot: daemon listening under the latency budget; bound instance id equals the provider's; every identity item differs between the two clones (machine-id, SSH host keys, daemon identity, WireGuard key, first `/dev/urandom` bytes); every store package runs (`--version`); `cr capabilities --json`; the agents' first interactive launch reaches the composer (the tmux screen check today's verifier does); idle CPU over 120 s under the budget and no process creations other than the sampler's; the secret scan; the SBOM generated and signed; Postgres reachable on the team role; the updater applies and rolls back a test manifest.
- Promotion stays a reviewed change to the image manifest; rollback is its revert (as today).

## 5. Team VM and servers

The team VM and self-hosted servers run the same "VM software" (spec SV1 to SV3; owned by the cmux server lane, plans/cmux-next/server.md). This image bakes what both need and does not decide the app-server or Postgres layout:

- Baked: PostgreSQL 17 server and client binaries (PGDG, pinned), JuiceFS, workerd, the `cmux` binary with its server, team-host and automations-host roles, coderouter. All units are disabled in the image; the `team` role (and `cmux server up` on a server) enables what the server lane's design says.
- Not baked: a cluster, a port, roles, `pg_hba` rules or app databases. The server software creates them at first start, after bind, so no two machines share a cluster identity or a password, and the server lane owns their layout (unique port per install, local-only listener, per-app roles; SV2).
- Image facts the server lane needs: the private network interface is attached after resume, so an address list frozen at snapshot time does not include it (a listener that must reach the team network binds at start, not at bake); a cluster running in the snapshot slowed `vms.create` from 98 to 254 ms to 435 to 491 ms (n = 10), so the cluster is stopped at snapshot time and started at bind; after resume a running cluster answered a peer-auth `select 1` in 112 to 124 ms (n = 10); the cluster at idle used 25.6 MB PSS and 0.012 CPU-s/min.
- One store for both: a server installed with the curl command and a VM use the same store layout (section 4.5), the same channel manifest and the same updater, so "VM software" is one package set with one SBOM.
- Database files stay on local disk, never on the JuiceFS tier (a database on an object-storage filesystem pays a remote round trip per fsync); durability is the server lane's backup design.

## 6. Boot and per-clone identity

### 6.1 What a clone inherits

A Freestyle create from a snapshot resumes the memory image. Measured on clones of one snapshot: `boot_id`, `/etc/machine-id`, hostname, the eth0 MAC and its IPv6 and link addresses are identical; the monotonic and boot clocks jump forward by the snapshot's age, so every timer that expired in between fires in the first instant after resume. There is no VM generation id device (the kernel supports one; the hypervisor exposes none), so the kernel is never told it was cloned. The metadata service's `instance-id` is the only per-machine value.

Random state: in forks made seconds after a snapshot, the first read of `/dev/urandom` and a `getrandom()` call in a process that was running in the snapshot returned the same bytes on two of three forks. Clones made 100 s or more after the snapshot were unique (25 of 25), and all values diverged by 30 s. The explicit reseed at bind (`RNDRESEEDCRNG` with the instance id mixed in) is therefore required and must run before any key is made.

### 6.2 Detecting the clone without polling

Two signals reach the guest before `vms.create` returns: the provider's guest agent sets the realtime clock on every resume, which wakes a `CLOCK_REALTIME` timerfd armed with `TFD_TIMER_CANCEL_ON_SET` (p50 16 ms before create returns, n = 25), and the kernel reports the eth0 IPv6 address again over rtnetlink (p50 28 ms before, n = 25). The metadata service already answers with the new id at that moment (10 of 10 first reads). A third path is ours: the driver writes `/run/cmux/instance-id` right after create (lands about 25 ms after create returns) and an inotify watch wakes on it.

| Detector (5 clones each) | Clone confirmed, p50 / max, relative to create returning | Idle CPU-s/min | Wakeups/min | Weakness |
| --- | --- | --- | --- | --- |
| today: metadata poll every 1 s | +15 / +31 ms | 1.57 | 234 (+235 forks) | costs forever; a request in flight at snapshot time hangs on resume (one fork took 2,043 ms) |
| today while parked: poll every 50 ms | +20 / +40 ms | 18.5 | 3,295 (+3,295 forks) | 31% of a vCPU on the builder |
| inotify on the driver's file | +35 / +45 ms | 0.00 | 0 | misses clones made outside our driver |
| clock-set timerfd + rtnetlink | -17 / -7 ms | 0.00 | 1.8 | depends on provider agent behavior |
| both (proposed) | -10 / 0 ms | 0.00 | 0.8 | none found |

The resume signals also fire about ten times per control-plane call (each exec or file write) and never on an idle machine (0 in 300 s). Each wake costs one metadata read, so they are harmless.

Metadata service rules learned the hard way: concurrent readers stall (8 parallel readers: 18 of 160 requests hung to the 1 s timeout), and a request in flight when a snapshot or pause is taken hangs until its timeout after resume. So: one reader per machine, a 250 ms timeout, retries counted by attempts (a monotonic time budget expires across a pause), and no request in flight while parked.

### 6.3 Bind sequence

`cmux host run` (the one boot unit, a role of the `cmux` binary) blocks in one epoll set over the three signals. On a new instance id, in this order:

1. Reseed the kernel CRNG with the instance id mixed in.
2. Drop any inherited remote identity and connection state (as today), write the bound id, start the session host by direct spawn (not `systemd-run`: on a resumed clone systemd waits about 1.8 s before it starts the first transient unit; spawn to listening was 2,079 ms that way versus 260 ms direct).
3. Off the critical path: regenerate `/etc/machine-id` (and its D-Bus link) and the systemd random seed; generate SSH host keys (ed25519 only; RSA generation costs most of a second of CPU); generate the WireGuard key inside `cmux`; apply the role set and the machine's name from the binding; re-arm systemd timers after 10 min; run one store update check (section 4.5).
4. Supervise the session host by waiting on its process (pidfd), restart on exit. No tick.

Two traps found by the prototype: the host may set the clock again between reading the timerfd and re-arming it, so the re-arm itself fails with `ECANCELED` (drain and retry with a bound, never crash); and terminal host processes leave the session host's process group, so parking must stop them explicitly unless they are the intended warm template terminal. After `machine-id` changes, journald keeps writing under the old id's directory until it restarts; the bind sequence restarts it off the critical path.

The bake parks exactly as today (`/etc/cmux/bake-instance-id`): the session host stopped, no metadata request in flight, timers stopped, then the snapshot.

### 6.4 Private network announce

Today a clone sends a gratuitous ARP burst at bind and every 30 s, because an earlier measurement found the provider fabric dropped traffic to a clone until it transmitted. On 2026-10-02 a clone on a private network was reachable 7 s after create, and again after 8 and 40 minutes idle, with no announce (IPv4 and IPv6, 0% loss): the private VLAN interface is created at create time, so the kernel transmits on it by itself. Proposal: announce once at bind and on each resume signal (pause and start produce the same clock-set and address events), and drop the 30 s loop. Idle periods longer than 40 minutes and snapshots baked while already on a private network are UNVERIFIED; the CI smoke adds a 2-hour idle reachability check before the loop is removed in production.

### 6.5 Guest capabilities (measured)

Kernel 6.1.102 with everything built in and no loadable modules: WireGuard (`ip link add type wireguard` works, `wg` installed), `/dev/net/tun`, nftables and iptables-nft, IP forwarding on, cgroup v2 with cpu, memory, io and pids controllers and working user delegation (`systemd-run --user -p MemoryMax=… -p CPUQuota=…`), user namespaces (rootless overlay mounts work), overlayfs, loop devices, `/dev/kvm` (nested virtualization), systemd 255 with socket activation, Docker 29.1.3. FUSE works (`/dev/fuse` 0666) once the image installs `fuse3` (setuid `fusermount3`; add `user_allow_other` to `/etc/fuse.conf` for JuiceFS); POSIX ACLs work on the ext4 root once `acl` is installed. Pause takes 104 to 219 ms (the first call 7 s), start 71 to 217 ms; inotify watches survive, and monotonic timers count paused time.

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
2. "Event-driven bind depends on provider behavior (the agent setting the clock on resume)." Answer: the proposed detector uses two independent provider signals plus our own driver write, and confirms with the metadata service; the CI smoke fails a snapshot whose clones are not bound within the latency budget, so a provider change is caught before promotion.
3. "Postgres in every image costs disk for roles that never use it." Answer: 68 MB, disabled unit; one image is cheaper to bake, test and audit than two.

## 10. Surfaces

| Op | CLI | MCP | Palette | Notes |
| --- | --- | --- | --- | --- |
| `vm.image.show {machine}` (image id, store generation, channel, SBOM link) | `cmux vm image show <m> --json` | yes | "Show Machine Image" | read |
| `vm.image.update {machine, generation?}` | `cmux vm image update <m> [--generation G] --wait` | yes | "Update Machine Software" | idempotency key; waits until applied |
| `vm.image.rollback {machine, generation}` | `cmux vm image rollback <m> --generation G --wait` | yes | "Roll Back Machine Software" | |
| `vm.image.sbom {image}` | `cmux vm image sbom <image> --json` | yes | exempt (no UI value beyond show) | |

Settings: `cloud.machines.channel` (`stable` default, `beta`), `cloud.machines.desktop` (off by default), `cloud.machines.autoUpdate` (on; off pins the generation), `cloud.machines.setup` (a user or team script run once on each new machine after bind, off the critical path, output in the machine's log), `cloud.machines.dotfiles` (a git URL cloned into the work user's home after bind). Packages a team wants in the image itself are a later team layer, not phase 1. Team policy can enforce each (spec/enterprise.md). Right-click on a machine row: Update Machine Software, Show Machine Image.

## 11. Steps

1. `images/cmux-vm/` with the lock, the L1 recipe and the smoke; branch bakes with `cmuxnp-` names; numbers against section 3.
2. `cmux host` bind and supervisor role in the Rust binary (replaces `cmux-devbox-boot`), with the clone tests.
3. Store updater role, channel manifest signing in CI, files.cmux.com mirror.
4. Team role and servers: enable what the server lane specifies; JuiceFS after the storage spike; automations host.
5. Promote as the cmux-next default; today's devbox stays for the current app until cmux-next ships.

## 12. Decisions needed

Sent to the coordinator with recommendations (lane report): chief in the base image; signing key custody for the channel manifest; whether the 30 s network announce is removed in production; live versus dated apt sources for users; keep or remove the provider's Python; desktop off by default.

## 13. Production promotion plan (ready to run; needs Lawrence's approval)

Status 2026-10-02: prototype only. Lawrence decided that nothing reaches production before he approves this plan. No production snapshot was made and the production default did not change. This section promotes today's devbox recipe on `main` with the terminal-host idle-wakeup fix. The rest of this proposal (layers, store, bind agent) comes later and gets its own plan.

### 13.1 What changes for users

New machines get a cmux-tui that blocks on events. The terminal host's 20 ms accept-poll loop is gone. That loop ran in every terminal for its whole life, so an idle machine with one terminal woke about 50 times per second. Running machines keep their old terminal hosts until they are recreated. A daemon upgrade does not replace hosts: the daemon adopts every host and keeps it.

### 13.2 Rollback target (today's production default)

The production default is the `defaultForKind` rows of `web/services/vms/images/manifest.json` on `main`. The manifest was last changed by commit ee618231a8d. All rows were baked 2026-10-02T08:33Z (epoch 2026-09-10-r2, cmux-tui 37ee6af9846b). The desktop and base kinds share one snapshot per size:

| Size | Version (desktop / base `-base`) | Snapshot id |
| --- | --- | --- |
| sm | freestyle-cmux-devbox-workspace-1-sm | sh-6c0c7d26420c4666819f8beab3ea3282 |
| md | freestyle-cmux-devbox-workspace-1-md | sh-5d3c4477b81f4790aa913a638d0c1664 |
| lg | freestyle-cmux-devbox-workspace-1-lg | sh-29ad0dd38e244694b7ab24647b2b7c95 |
| lgx | freestyle-cmux-devbox-workspace-1-lgx | sh-805abf17226e43e68c47d20381132291 |
| xl | freestyle-cmux-devbox-workspace-1-xl | sh-fb6a0f4263b74fd68b3ed44c3ee96511 |
| 2xl | freestyle-cmux-devbox-workspace-1-2xl | sh-245b7fb7453b447c93daa769f96decc4 |

Rollback is one revert of the promotion commit on `main`, followed by the normal web deploy. Promotion only appends rows and demotes the old defaults, so the revert restores exactly these 12 rows as defaults. Nobody deletes these snapshots until 14 days after the promotion. Machines created from the new image keep running after a rollback; only new creates use the old snapshots again.

### 13.3 Preconditions

1. The idle-wakeup fix (feat-cmux-next 51b68635143, test af6cc545e4d) is on `origin/main`, and files.cmux.com has published that main commit's cmux-tui manifest. The bake pins it with `CMUX_VM_CMUX_TUI_MANIFEST_URL=https://files.cmux.com/cmux-tui/<main sha>/manifest.json`, so the two ladders cannot straddle a publish.
2. The verifier's idle-wakeup and clone-identity checks (this branch: `devboxIdleWakeupCheckCommand` in `web/scripts/devbox-image-common.ts`, wired in `web/scripts/verify-devbox-image.ts`, tests in `web/tests/vm-devbox-idle-wakeups.test.ts`) are on `main`. `promote-devbox-image.ts` runs the verifier from the checkout it runs in, so the promotion gates on the new check only after that commit is on `main`.
3. `bun run devbox:manifest:check` passes on `main`, and no other promotion PR is open (two in flight conflict on `manifest.json`; README "Two promotions in flight").

### 13.4 Who runs it

The VM image lead runs the bake, verify and derive from a clean `main` worktree, with the production Freestyle key from `~/.secrets/freestyle-beta.env` (path only; never printed). The promotion PR merges only after Lawrence gives a direct merge directive for that PR. The coordinator relays the approval.

### 13.5 Bake and promote (commands)

From `web/` in a clean worktree at the approved `main` SHA:

```bash
bun install --frozen-lockfile
CMUX_VM_CMUX_TUI_MANIFEST_URL=https://files.cmux.com/cmux-tui/<main sha>/manifest.json \
  bun run devbox:promote -- freestyle --kinds desktop,base --out /tmp/promo-<sha>.json
```

The script bakes once (about 4 min), runs the verifier on the bake, derives the six sizes in parallel (about 30 s), and appends the rows. It writes the manifest only after verification passes. Then commit the manifest diff on a branch, open a PR into `main` with the evidence below, and stop.

### 13.6 Smoke test (all must pass; the verifier runs every item)

- Daemon: it comes up by itself, is bound to this instance id, and matches the baked pin. The WebSocket smoke and the terminal identity environment pass.
- Idle wakeups (new): over a quiet 60 s, the voluntary context switches of each terminal host's main thread are at most 30. They are counted per thread from `/proc/<pid>/task/<tid>/status`, the same method as the repro. The check fails when no terminal host exists. It also prints every daemon thread for the record.
- Per-clone identity, on two machines from the snapshot: daemon identity and machine secrets differ; SSH host keys differ. `/etc/machine-id` and `boot_id` are reported. The machine id is shared on today's recipe, because the bake never regenerates it. `--strict-clone-identity` makes that a failure, and it stays off for this promotion; regenerating the machine id at bind is the follow-up in section 6.3. The verifier cannot prove the RNG reseed: by the time it reads, both kernels have already used randomness, so their output differs even when the clones resumed with one state. The reseed stays in `cmux-devbox-boot` (proven by the early-fork test in section 6.1). A bind-time record of the first random bytes, for the verifier to compare, comes with the bind agent.
- Agents: every pin, and the first interactive launch of Claude Code and Codex reaches the composer.
- Desktop contract: both ports, the session processes, and `cua-driver doctor`.
- Every baked file is byte-identical to the checkout.
- Sizes: `nproc`, memory, disk and the daemon on every derived size.

### 13.7 Evidence for approval (in the promotion PR)

1. The verifier log for the bake: `ALL CHECKS PASSED`, plus the idle-wakeup lines showing the terminal host's main thread at or under 30 switches in 60 s.
2. The same verifier run against the current production md snapshot sh-5d3c4477b81f4790aa913a638d0c1664 shows the idle-wakeup FAIL. That proves the check sees the old loop.
3. A measurement on 5 clones of the new md snapshot against the old one: create, first exec and daemon-ready p50/p95; idle CPU-s/min over 300 s; process creations per minute; the terminal host's and the daemon's voluntary switches per minute.
4. The derive summary: one id per size, each booted and checked.
5. The secret check: the model-plane file holds no `crt_` token (the bake's own step).

### 13.8 Canary and rollout

1. After the PR merges, wait for the production deploy to be READY. Then create a machine through the production API with the sanctioned smoke (`bun scripts/cloud-vm/smoke-vm-api.mjs production --create --provider default --paid --edge-check`, the form the canary workflow uses). Attach from a released Mac app to the md machine, run one agent, and delete the machines.
2. Watch the scheduled `Cloud VM canary` workflow (every 5 min against production) for three consecutive green runs. Watch create errors and attach failures in Axiom (`cmux-prod-otel-traces`, `POST /api/vm`, `POST /api/vm/[id]/attach-endpoint`) for 60 minutes against the previous day's rate.
3. Roll back (section 13.2) on any of these: a failed canary that passes again after the revert; an attach failure rate above the previous day's; a verifier or smoke regression found later.
4. Running machines are not touched. If the old host loop on long-lived machines needs fixing before users recreate them, that is a separate, opt-in fleet action: new terminals need a new host. `upgrade-fleet-cmux-tui.ts` replaces only the daemon, and the daemon adopts old hosts.

### 13.9 Prototype evidence (2026-10-02, no production change)

- The verifier with the new check failed on the production md snapshot sh-5d3c4477…: the terminal host's main thread made 3,000 voluntary switches in 60 s (`FAIL 1 terminal host main thread(s) over 30 switches in 60s`). In the same window the old daemon's main thread made 241 and its journal thread 121.
- A prototype bake, `cmuxnp-dev-fixbake-f39636c-exp20261002t1800z` (sh-fbc2c142fc174b5d8f9bc3f3bd798dc0), was made from this branch with cmux-tui f39636c811aa, the feat-cmux-next build that contains the fix. The fix was not yet on `main`. The verifier gave `ALL CHECKS PASSED`, and the idle check measured 0 switches in 60 s on the terminal host's main thread. Every daemon thread was at 0, except one thread at 2. The strict clone-identity run failed only on the shared machine id (`48e14341…` on both machines, the same id as the production image).
- 5 clones each, measured in parallel with the same script. The old image is md (4 vCPU) and the prototype is sm (2 vCPU), the size the bake makes before derivation:

| | old (production md) | fix prototype (sm) |
| --- | --- | --- |
| create p50 / p95 | 216 / 340 ms | 159 / 166 ms |
| first exec p50 / p95 | 261 / 373 ms | 185 / 200 ms |
| daemon ready p50 / p95 (in-guest 50 ms poll) | 3,839 / 4,067 ms | 805 / 950 ms |
| idle CPU, whole VM, 300 s | 2.87 CPU-s/min | 2.12 CPU-s/min |
| terminal host: CPU, voluntary switches | 0.114 CPU-s/min, 2,981 per min | 0, 0 |
| daemon voluntary switches | 426 per min | 2 per min |
| kernel `rcu_preempt` switches | 6,589 per min | 1,233 per min |
| context switches, whole VM | 556 per s | 231 per s |
| process creations | 463 per min | 454 per min |

The remaining idle CPU is the boot supervisor's 1 s metadata poll (about 1.4 CPU-s/min) and the desktop supervisor (about 0.4). Sections 4.4 and 6 remove them; this promotion does not.

### 13.10 Rebake from `main` with the fix (2026-10-02, prototype, deleted)

The fix reached `main` as 9a332eca4bbc (#16864, host accept loop only). I baked `cmuxnp-dev-mainbake-9a332ec-exp20261002t2000z` (sh-753a06c15d454c2597ab67b93c124594) from that `main` commit, with the cmux-tui pinned to the commit's files.cmux.com manifest. I then ran the full verifier with the idle check from section 13.6 on top. Result: `ALL CHECKS PASSED`. The terminal host's main thread made 0 switches in 60 s. Daemon identity and SSH host keys differed across the two clones. The machine id and boot_id were shared, as expected. The snapshot and every VM are deleted.

Same size (sm, 2 vCPU), same scripts. Idle is one settled clone each over 300 s.

| | production sm (sh-6c0c7d26…, cmux-tui 37ee6af9846b) | main rebake (cmux-tui 9a332eca4bbc) |
| --- | --- | --- |
| terminal host | 0.138 CPU-s/min, 2,979 switches per min | 0, 0 |
| daemon voluntary switches | 426 per min | 426 per min (main's daemon still has the polls that feat-cmux-next removed in 51b68635143: main thread 241, journal 121 and session journal 61 per minute) |
| kernel `rcu_preempt` switches | 6,583 per min | 1,297 per min |
| context switches, whole VM | 528 per s | 250 per s |
| idle CPU, whole VM | 3.14 CPU-s/min | 2.76 CPU-s/min |
| process creations | 461 per min | 462 per min (boot supervisor poll, unchanged) |
| daemon ready, interleaved creates (n = 8 each) | p50 868 ms, p95 1,967 ms | p50 875 ms, p95 7,191 ms |

Daemon readiness has the same median but a worse tail on this snapshot. In the interleaved run, 2 of 8 clones of the rebake waited 4.3 and 5.1 s inside the guest. The worst production clone waited 1.6 s. Earlier runs at a time of high provider variance showed slow clones on both images. An earlier lane prototype showed a stall of this kind that belonged to one snapshot (section 4.3). The cause is UNVERIFIED. The promotion evidence (13.7, item 3) must therefore include an interleaved 10-clone readiness comparison against production. A p95 more than 1 s above production blocks the promotion until the cause is known.
