# cmux server: headless Linux prototype

Lane 10 step 3 (plans/cmux-next/server.md section 15). It proves the install chain, the systemd user service with the real session host, Postgres per SV2, headless Chromium and the Linux health inhibitor on a Freestyle VM. Measured on 2026-10-02.

Everything here is a prototype. The Rust `cmux server install` and `cmux host run` do not exist yet. The shell functions marked "PROTOTYPE (binary step)" in `install.sh` do what those commands will do, so they are the executable specification for the Rust code.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | POSIX sh installer (server.md 4.2). Everything is in functions and `main` runs on the last line. A CI-written GENERATED block holds the per-target bootstrap URL, size and SHA-256, plus two Ed25519 release keys. |
| `install.ps1` | Windows draft. **UNVERIFIED: never executed.** |
| `cmux-host-run` | Stand-in for the frozen unit command `cmux host run`. It is shipped as its own store package so manifests can change it. |
| `cmux-archive-wal` | Stand-in for `cmux server db archive-wal`: copy, fsync, rename, fsync dir. |
| `build-test-channel.sh` | Builds a throwaway signed channel: test keys, bootstrap archive, manifests v1, v2, expired, badsig and tampered, and the installer with its GENERATED block filled. |
| `tests/install-cases.sh` | One installer case per call, run as the non-root user. |
| `tests/pg-*.sh` | Postgres in user mode, in system mode, and point-in-time restore. |
| `tests/chromium.sh` | chrome-headless-shell at a pinned version, with the sandbox. |
| `tests/idle-cost.sh` | cgroup CPU and memory, context switches and process creations over a window. |

## Setup

- VM: one Freestyle VM from `freestyle/ubuntu-sm`: Ubuntu 24.04.5, kernel 6.1.102, 2 vCPU, 3.9 GiB, 16 GB. `vms.create` took 453 ms. The VM had `ttlSeconds` 86400 and was deleted by id after the run.
- Test user: `srvtest`, uid 1001, created with `useradd`. It has no sudo. All user-mode steps ran as this user through the Freestyle exec API (`linuxUser`), with no login session.
- Payload: the real pinned cmux-tui `f39636c811aa` (`scripts/cmux-next/cmux-tui.pin`). The pin file names only the macOS asset. The same commit's `manifest.json` on files.cmux.com lists `cmux-tui-x86_64-unknown-linux-musl` (sha256 `a327d257…`, 44,497,856 bytes, static), and the manifest's `cmux` package uses that public URL. v2 also adds the real `cmux-tui-hook` for the same commit.
- Channel: served by `python3 -m http.server --bind 127.0.0.1 8765` inside the VM. The installer accepts `http://127.0.0.1` URLs only when the GENERATED block sets `CMUX_TEST_CHANNEL=1`. Otherwise it requires `https://` and curl `--proto =https`.
- shellcheck 0.9.0 ran on the VM: `shellcheck -s sh -x -P SCRIPTDIR` over every `.sh` file and both stand-ins. The result is clean.

## Install chain results

The log is from the final run of `tests/install-cases.sh`, after every fix below.

| Case | Result | Key output |
| --- | --- | --- |
| cut download (first 6,000 bytes piped to `sh`) | PASS | syntax error at EOF, nothing created |
| fresh install `curl … \| sh -s -- --version 1` | PASS | 1.9 to 2.1 s, including the 44 MB cmux download. Store, profile 1, `current` flip, shim, units, start. State dirs are 0700 and `updater.state` is 0600. |
| client on the socket | PASS | `workspace create`, `tab create terminal`, `terminal write`, `screen wait`, `screen read` show `proto-marker-42`. `cmux daemon status --json` reports the session `server` at `/run/user/1001/cmux-tui-1001/server.sock`. |
| idempotent rerun | PASS | 0.93 to 0.98 s. Store hits, "no change", unit not rewritten, same MainPID. |
| upgrade to v2 (cmux-host-run 2, adds cmux-hook) | PASS | 1.5 to 3.7 s. The manifest was signed with the *next* key and was accepted. The session host was restarted (new PID). |
| terminal across the upgrade restart | PASS | The shell keeps the same PID under the same terminal host PID, the new daemon adopts it, and the screen still shows the marker. |
| rollback to generation 1 | PASS | 0.22 to 2.3 s, including the service restart. The flip is one `rename(2)` (`mv -T`). |
| tampered package (one byte changed, same size) | PASS (refused) | `SHA-256 mismatch for package cmux-host-run … refusing`. `current` did not change. |
| bad signature (untrusted key) | PASS (refused) | `manifest signature is invalid for both release keys; refusing` |
| expired manifest | PASS (refused) | `expired at … (now …); refusing` |
| downgrade (sequence 1 after 2) | PASS (refused) | `sequence 1 is lower than the last applied 2 (downgrade or replay); refusing. Use --rollback …` |
| re-upgrade from the store | PASS | 1.2 s, all store hits |
| uninstall | PASS | 0.33 to 0.39 s. Store, profiles, shim and units are removed. State is kept (Postgres data dir, app pgpass files, backups, install id). 0 server processes are left. |
| uninstall `--purge` | PASS | State dir removed, 0 server processes left |
| `--system` | PASS (refused as designed) | It runs only `sudo <verified bootstrap>` and checks first that the binary has `server install`. The pinned binary does not have it, so the script stops with "system mode is UNVERIFIED". |
| reboot survival with linger | PASS | See below. |

Readiness: `cmux-server.service` is `Type=forking` with a `PIDFile`. `ExecStart` runs `cmux daemon ensure --session server --json`. That command returns only after the owner answers identify with `lifecycle_ready`. So `systemctl --user start` returns when the server is ready, and the installer has no sleep loop. The polling stays inside cmux-tui's own ensure. `KillMode=process`: a stop or restart sends SIGTERM only to the session host, so terminal hosts survive for adoption (docs/cloud-guest-upgrades.md).

Linger:

| Base | `loginctl enable-linger <user>` as the user |
| --- | --- |
| Freestyle `ubuntu-sm` (no `polkitd`) | refused: `Could not enable linger: Access denied`. The installer prints `sudo loginctl enable-linger srvtest`, stops, and never runs it itself. After root ran it, `user@1001` was active in 147 ms. |
| with stock `polkitd` 124 (Ubuntu Server ships it) | allowed without sudo (`org.freedesktop.login1.set-self-linger`: implicit any = yes) |

`loginctl enable-linger` with no user name fails with ENXIO when there is no session. Pass the name.

Reboot: `systemctl reboot` in the guest. The guest shutdown took 0.6 s. Freestyle booted the VM again by itself after about 8 s (stopped, then running). Then, measured as monotonic time since the kernel started:

| Unit | Ready at |
| --- | --- |
| kernel + userspace (`systemd-analyze`) | 0.99 s + 2.69 s |
| system Postgres (system mode) | 2.23 s |
| `user@1001.service` | 2.48 s |
| user Postgres | 2.58 s |
| `cmux-server.service` (start took 274 ms) | 2.76 s |
| inhibitors | 2.78 s |

Terminals from before the reboot report `host-process-ended-before-adoption`, as expected.

## Postgres (SV2)

PostgreSQL 17.11 came from PGDG apt as root, with `create_main_cluster = false`, so no cluster runs on 5432. The install took 16 s. Clusters were then created as below (`tests/pg-common.sh` holds the shared rendering).

User mode (`tests/pg-user-mode.sh`, run as `srvtest`):

- The command is `initdb --data-checksums --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=reject --username=cmux_admin`. It took 712 ms. The user unit is `Type=notify` and started in 127 ms.
- The port is `15432 + fnv1a64(install_id) % 10000`. It was 18606 for one install id and 17449 for another.
- `listen_addresses = ''`. The socket dir `<state>/postgres/run` is mode 0700. `pg_hba.conf` is generated in full and ends with `reject`.
- `archive_command` runs `cmux-archive-wal`.
- Apps `notes` and `crm` each get a role with `CONNECTION LIMIT 20`, `statement_timeout 30s`, `idle_in_transaction_session_timeout 60s` and `temp_file_limit 1GB`. Each gets an owned database, `REVOKE ALL … FROM PUBLIC` and `REVOKE CREATE ON SCHEMA public`. Each gets a random 32-byte secret in a 0600 `pgpass`.
- Passwords reach the server only as SCRAM verifiers, computed client-side. The clear secret never appears in SQL, logs or argv.

| Check | Result |
| --- | --- |
| no TCP listener (`ss -ltnp`) | PASS |
| app_notes opens app_notes | PASS |
| app_notes cannot open app_crm | PASS (`pg_hba.conf rejects connection`) |
| app_notes cannot log in as app_crm | PASS (`no password supplied`) |
| only app roles have a password | PASS (`app_crm,app_notes`) |
| ACLs, role limits, file modes 700/600/700 | PASS |
| another OS user (`srvtest2`) | cannot read the state dir or reach the socket (`Permission denied`) |
| cmux_admin by peer for the service user | works |
| **an app process cannot become cmux_admin** | **FAIL (design gap).** In user mode every app runs as the service user, so peer maps it to `cmux_admin`. |

Fix tested (`pg-user-mode.sh sandbox`):

- `cmux_admin` uses SCRAM with a secret in `<state>/postgres/admin.pgpass` (0600).
- Each app runs in a bubblewrap mount namespace: a tmpfs over the state dir, with only its own app dir and the socket dir mounted back.

| Check (inside the sandbox) | Result |
| --- | --- |
| the app reaches its own database | PASS |
| `cmux_admin` | refused (`no password supplied`) |
| the admin secret | not visible (`No such file`) |
| the other app's pgpass | not visible (`No such file`) |

Landlock on kernel 6.1 cannot restrict `connect()` to a pathname socket, so a mount namespace is the tool here.

System mode (`tests/pg-system-mode.sh`, as root once):

- Service user `cmux` (group `cmux-db`). OS users `app-notes` and `app-crm` are members of `cmux-db`.
- System unit with `RuntimeDirectory=cmux/postgres` (0750, `cmux:cmux-db`). The socket is 0770, group `cmux-db`.
- Peer auth through the `pg_ident` maps `cmuxadmin` and `cmuxapps`. initdb took 793 ms and the start took 211 ms.
- All 10 checks PASS:
  - no TCP listener;
  - each app opens only its own database;
  - `app-notes` cannot log in as `app_crm` or `cmux_admin` (`Peer authentication failed`);
  - only `cmux` maps to `cmux_admin`; root is refused;
  - a non-member gets `Permission denied` on the socket;
  - no role has a password (0).

Backups (`tests/pg-pitr.sh`, user mode):

| Step | Result |
| --- | --- |
| `pg_basebackup -Ft -z -X none -c fast` | 1.9 to 2.0 s, 5.1 MB |
| write and archive | 10,000 rows inserted, `pg_switch_wal()`, table dropped, WAL switched again. The script waited on `pg_stat_archiver` and nothing failed (10 archived, 0 failed). |
| restore into a new data dir | `recovery_target_time` set before the drop, port +2, its own socket dir |
| **result** | **PASS: 10,000 rows back. Restore to promoted and queryable in 945 to 1,128 ms.** Log: `recovery stopping before commit of transaction …`, `archive recovery complete`. |

## Headless Chromium

- Version: chrome-headless-shell 154.0.8037.92 (stable), from the Chrome for Testing `known-good-versions-with-downloads.json`, pinned in `tests/chromium.sh`.
- Zip: sha256 `636aa5c79f2693632e9921b8bbb050038ba11672e02346c06c20f991aed096f9`, 120,477,194 bytes.
- Binary: sha256 `7c141b276aacc74fe51f06986345fb0dbce0e3756413746fb18541b878c17706`.
- The base image lacks its shared libraries. Root installed `libnss3`, the atk and atspi libraries, `libcups2t64`, `libxkbcommon0`, the X client libraries, `libgbm1`, `libpango`, `libcairo2`, `libasound2t64` and `fonts-liberation` (9 s).

Results:

- As `srvtest`, with the sandbox on (no `--no-sandbox` anywhere), `--dump-dom` worked:
  - local page with JavaScript: 290 to 310 ms, `js ran 42`;
  - `https://example.com`: 275 to 292 ms, "Example Domain".
- With `--remote-debugging-pipe`, a renderer had seccomp mode 2 (filter), its own user namespace, its own PID namespace and its own network namespace. **PASS**
- Kernel facts on Freestyle 6.1.102:
  - `kernel.apparmor_restrict_unprivileged_userns` does not exist;
  - AppArmor is off (LSMs: `capability,selinux`);
  - `user.max_user_namespaces` = 15641;
  - `unshare -Ur` works.

So the Ubuntu 23.10+ restriction does not apply on this kernel. The AppArmor-profile fix is **UNVERIFIED**: it needs a stock Ubuntu kernel. The planned profile for system mode is `profile cmux-chrome <store path>/chrome-headless-shell flags=(unconfined) { userns, }`, loaded with `apparmor_parser -r`.

## Health (server.md 9.1)

`cmux-server-inhibit.service` (PartOf `cmux-server.service`) holds logind inhibitors with `systemd-inhibit … /bin/sleep infinity`. The Rust health role will hold them as D-Bus file descriptors instead.

| Condition | Result |
| --- | --- |
| no polkitd | every inhibit: `Failed to inhibit: Access denied`. The first unit restarted every 5 s; it now has `StartLimitBurst=3`. |
| stock polkitd, lingering user without a session (polkit subject "any") | `idle` allowed, `sleep` refused (`inhibit-block-sleep`: implicit any = no) |
| combined `--what=sleep:idle` | logind checks the polkit action `inhibit-handle-lid-switch` for a combined mask, not the sleep action. A rule that allows only the sleep and idle actions does not make it pass. |
| fix (as root, which system mode installs) | `/etc/polkit-1/rules.d/50-cmux-server.rules` allows `inhibit-block-sleep` and `inhibit-block-idle` for the service user. The installer then holds one inhibitor per kind, and `systemd-inhibit --list` shows `cmux-server … sleep … block` and `cmux-server … idle … block`. |

The installer probes each kind and holds what it may. It warns about the rest. The VM was never suspended.

## Idle cost (120 s, after the reboot)

One live idle terminal; `tests/idle-cost.sh`, cgroup `cpu.stat` and `memory.current`, PSS from `smaps_rollup`.

| cgroup | CPU-s/min | memory.current | PSS |
| --- | --- | --- | --- |
| `user@1001.service` (whole user service set) | 0.031 | 105.2 MiB | |
| `cmux-server.service` (session host + 1 terminal host + bash) | 0.0002 | 71.9 MiB | 63.1 MiB |
| `cmux-postgres.service` (user) | 0.031 | 25.6 MiB | 21.7 MiB |
| `cmux-server-inhibit.service` | 0.0000 | 2.2 MiB | 2.9 MiB |
| system-mode Postgres (for comparison) | 0.031 | 42.2 MiB | 21.8 MiB |

- Context switches per second: session host 0.00, terminal host 0.00, bash 0.00, Postgres background writer 1.68, walwriter 0.20, autovacuum launcher 0.20, postmaster 0.13.
- Process creations on the whole VM: 18 in 120 s (9.0 per minute). This includes the measuring script's `sleep` and the provider agent.
- The user service set is far below lane 1's budget of 0.2 CPU-s/min. Nearly all of it is the Postgres background writer.

## UNVERIFIED

- `--system` install end to end. The binary has no `server install --system` yet, so the polkit rule, the system unit and the store under `/opt/cmux` were done by hand only for Postgres and the inhibitor.
- The AppArmor fix for Chromium (no AppArmor in the Freestyle kernel).
- `install.ps1` (never executed).
- aarch64 and macOS.
- The relocatable `postgresql-17` store package (this run used PGDG apt).
- The final base backup before `--purge`.
- Freestyle `poweroff` behavior (only `reboot` was tested).
- Idle cost over more than 120 s, and with a client attached.
