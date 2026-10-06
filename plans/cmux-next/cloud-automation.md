# cmux next: Cloud automation (browser use and computer use on Linux hosts)

Status: proposal, 2026-10-04. Owner: the cmux-next Cloud automation image lead, reporting to the umbrella owner (session cmuxterm-hq-a9, decisions CLOUD-OWNER and CLOUD-PRIORITY). Spec owner: the coordinator. This file proposes; it changes no image, no Freestyle resource and no code.

Binding inputs: decisions CLOUD-OWNER, CLOUD-BROWSER-DISPLAY, CLOUD-WATCH, CLOUD-LOGIN, CLOUD-PRIORITY, REMOTE-TAB (RT1 to RT14, mainly RT2, RT7, RT8), LINK-FILES, SSH-1, V2, V3; plans/cmux-next/vm-image.md, server.md, remote-tab.md, computer-use.md, browser-host.md, cloud-client-contract.md sections 1.7 and 2.4; spec/team-vm.md "SSH access".

Scope: what a cmux Cloud VM and a cmux server Linux host must contain and run so that agents can use a browser and computer use there, at about 0 idle CPU, sandboxed, and reachable for files over the `ssh` link service.

## 0. Findings (state on feat-cmux-next d41372ae2ea, 2026-10-04)

1. The cmux-next image pipeline exists and has no active owner since the V2/V3 decisions (2026-10-02). Under CLOUD-OWNER this lane owns it now (section 1).
2. The cmux-next image installs no browser, no display, no CUA host and no SSH CA trust. `inputs.lock.json` has no Chrome, no chrome-headless-shell, no Xvfb, no cmux-cua. `openssh-server` comes from the provider base with stock config.
3. The classic devbox (web/services/vms/images/devbox/Dockerfile:139-173) installs Xvfb, floating `google-chrome-stable_current` and cua-driver 0.23.2. We do not copy that recipe and we do not edit it.
4. `cmux-browser-host` is a separate binary target (`src/bin/cmux-browser-host.rs`). No crate links it into the `cmux-tui` binary and `cmux-tui-artifacts.yml` does not publish it to files.cmux.com. So no image can ship it today.
5. `pipe.rs` `default_args()` always passes `--headless` (new headless, full Chrome browser layer on Ozone headless) and also `--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`. The last three keep background tabs at full timer rate, which works against the idle budget (section 6).
6. `manaflow-ai/cmux-cua` has a Linux release workflow (`cd-rust-cua-driver.yml`, tags `cua-driver-rs-v*`, x86_64 and aarch64) but no published release. cmux pins cmux-cua by source SHA only for macOS (`scripts/build-cmux-cua.sh`). So there is no pinned Linux binary to put in the lock.
7. The server Linux prototype (`server/prototype/linux/`, README "Headless Chromium") proved chrome-headless-shell 154.0.8037.92 runs sandboxed on Freestyle kernel 6.1.102: seccomp mode 2, own user, PID and network namespaces; AppArmor is off on that kernel, `unshare -Ur` works. The full Chrome layer under the sandbox is UNVERIFIED (remote-tab.md section 11).
8. Chrome for Testing has no linux-arm64 build. aarch64 Linux servers need another Chromium source (section 2.2).
9. The only browser host test with a real Chromium is `cdp-browser-smoke` in `cmux-tui.yml` (dispatch only, `mode: full`, 25 min timeout, Playwright Chromium, headless). No CI runs Chromium in a display or cmux-cua on X11 in this repo.

## 1. Image pipeline: ownership and state

### 1.1 Ownership

| Entity | Owner (single writer) | Others |
| --- | --- | --- |
| Image definition: `images/cmux-vm/inputs.lock.json`, `web/scripts/cmux-vm-image/*`, `images/cmux-vm/guest/*`, `.github/workflows/cloud-vm-image-bake.yml` | Cloud automation image lead (this lane) | other lanes request package changes through this lane |
| vm-image.md | this lane (adopted; the original VM image lead is inactive) | coordinator imports to spec/plan-vm-image.md |
| Production image manifest (`web/services/vms/images/manifest.json` on `main`) | the promotion change, approved by Lawrence (V3) | this lane prepares, never merges alone |
| Classic devbox (`web/services/vms/images/devbox/`) | classic Cloud (untouched by cmux-next lanes) | none |
| `cmux host run` bind and supervisor role (vm-image.md step 2) | cmux-tui session host owner (crate slot) | this lane writes the image side |
| Display supervisor, per-session cgroups | session host owner | this lane specifies, CUA lead consumes |

Proposed CODEOWNERS line (needs Lawrence; CODEOWNERS today covers only `/.github/workflows/`): `/images/cmux-vm/ @lawrencecchen`.

### 1.2 What exists

- Lock: `images/cmux-vm/inputs.lock.json` (base fingerprint of `freestyle/ubuntu-sm`, Ubuntu snapshot 20261001T000000Z, PGDG 17, 10 store programs with sha256, syft).
- Bake: `bun ../images/cmux-vm/bake.ts --tag <tag>` from `web/` (wrapper over `web/scripts/cmux-vm-image/bake.ts`, 438 lines). Names every VM and snapshot `cmuxnp-dev-vmimg-<tag>` unless `--promotion`; records every id in a ledger; `cleanup.ts --ledger` deletes by id.
- Smoke: `smoke.ts --snapshot S --clones N` (latency, binding, per-clone identity, idle CPU and wakeups via `guest/sampler.py`, programs run, secret scan).
- Reproducibility: `repro.ts` (two bakes, SBOM and file-hash diff).
- CI: `cloud-vm-image-bake.yml`, `workflow_dispatch` only, environment `cloud-vm-image-checks`, secret `FREESTYLE_API_KEY`.
- Lock test: `web/tests/vm-image-cmux-vm-lock.test.ts`.

### 1.3 What is missing

| Gap | Effect | Proposed fix | Owner |
| --- | --- | --- | --- |
| No push trigger on `images/cmux-vm/**` (vm-image.md 4.11 says there is one) | a lock change is never baked unless someone dispatches | add the path trigger after the key move below | this lane |
| CI key: `cloud-vm-image-checks` `FREESTYLE_API_KEY` is the shared-account key used by the classic reachability check (account UNVERIFIED by this lane; secret not read) | branch bakes land on the account that serves production | new environment `cmux-next-vm-image-dev` with the cmux-next dev key (`freestyle-cmux-next-dev-20261004.key`); keep `cmuxnp-dev-` names; needs a repo admin to add the secret | Lawrence (secret), this lane (workflow) |
| `bake.ts` reads the key only from the environment | the key must pass through a shell variable | add `--api-key-file <path>` (read in process, never logged) | this lane |
| Boot still uses `cmux-devbox-boot` (the classic 1 s metadata poll) | idle CPU and bind latency of today | `cmux host run` (vm-image.md step 2) | session host owner |
| Store updater, channel manifest signing | no update without rebake | vm-image.md step 3 | this lane + backend |
| Lock `programs[].roles` is empty | `cmux host` cannot start units by role | fill roles; lock test rejects an empty role list | this lane |
| No browser, display, CUA, SSH CA (findings 2, 4, 6) | no browser use or CUA on cmux-next VMs | sections 2 to 5 | this lane + owners named there |
| No browser, CUA or sshd checks in the smoke | regressions pass the gate | section 8 | this lane |

## 2. Package and role set

One image for every cmux Linux machine (V2). Packages are in the image; units start on demand by role. A role that is off costs disk only.

### 2.1 Roles

| Role | Runs | Started by | Default |
| --- | --- | --- | --- |
| `browser` | `cmux browser host` (agent ops, lease, REPL, CDP over `--remote-debugging-pipe`) + a Chrome engine process tree per profile | session host on the first `browser.*` op; stops after idle (DemandTimer) | allowed on every machine |
| `remote-browser` (RT r7) | `cmux-remote-browser` (RT2 stream host) + fork Chrome with remote presentation | session host on the first remote tab open | allowed once r1 and r2 ship; package slot reserved now |
| `cua` | `cmux-cua serve` (one per machine) | session host on the first `cua.*` op | allowed on every machine |
| `display` (internal to `cua` and `desktop`) | Xvfb (default) or nested `cua-compositor`, openbox, an AT-SPI bus, per display | session host, only for CUA on non-browser desktop apps (RT8) or for `desktop` | never at boot |
| `desktop` (vm-image.md 4.4) | the human VNC view on top of the same display supervisor | `cmux vm open <m>:desktop` | off |
| `ssh` | sshd, loopback only, trusts the CA from the instance binding | socket activation | on; refuses everyone until bind writes a CA |

RT8 rule: the agent browser never needs a display. Browser use goes through CDP into Chrome on Ozone headless (today) or through the remote presentation fork (later). A display starts only when an agent uses CUA on a desktop app.

### 2.2 Packages (all pinned by version and sha256 in the lock; sizes are estimates until the first dev rebake measures them)

| Package | Role | Source | Est. installed |
| --- | --- | --- | --- |
| `cmux-browser-host` binary (later the `cmux browser host` subcommand) | browser | files.cmux.com by commit (needs a publish step, section 9) | 15 MB |
| Chrome engine, stage A: Chrome for Testing (full Chrome, `chrome` binary), same major as the CEF fork pin | browser | CfT `known-good-versions-with-downloads.json`, our sha256, mirrored to files.cmux.com | 350 MB |
| Chrome engine, stage B: fork Chrome with remote presentation (manaflow-ai/cef, RT2) | remote-browser, then browser | our fork CI artifact, x86_64 and aarch64 | 400 MB (estimate) |
| Chrome runtime libraries (`libnss3`, `libgbm1`, `libasound2t64`, `libatk-bridge2.0-0t64`, `libcups2t64`, `libxkbcommon0`, `libxcomposite1`, `libxdamage1`, `libxrandr2`, `libpango-1.0-0`, `libcairo2`, the X client libraries) | browser | Ubuntu snapshot, exact versions | 60 MB |
| Fonts: `fonts-liberation2`, `fonts-dejavu-core`, `fonts-noto-core`, `fonts-noto-color-emoji`, `fonts-noto-cjk` | browser, display | Ubuntu snapshot | 120 MB (CJK is most of it) |
| `cmux-cua` Linux binary (pinned build, replaces cua-driver 0.23.2) | cua | manaflow-ai/cmux-cua release `cua-driver-rs-v<ver>`, sha256 + attestation (no release exists yet, section 9) | 30 MB |
| `xvfb`, `xauth`, `openbox`, `at-spi2-core`, `dbus-user-session`, `libxtst6`, `libxi6` | display | Ubuntu snapshot | 40 MB |
| `ffmpeg` (CUA session video on Linux, computer-use.md 4) | cua | Ubuntu snapshot | 90 MB; alternative: record frames only and drop video on Linux (decision D-A5) |
| `cua-compositor` (nested Wayland, alternative to Xvfb) | display | cmux-cua nix build | deferred; Xvfb first |
| Encoders for remote tabs (x264 or openh264, libopus) | remote-browser | decided with RT r2 (codec license, decision D-A6) | deferred |
| `openssh-server` | ssh | already in the base (`1:9.6p1-3ubuntu13.19`), config from section 5 | 0 new |

Not shipped: chrome-headless-shell. RT8 allows it for agent-only throwaway sessions, but full Chrome in `--headless` mode covers those sessions too, so one engine, one sandbox proof and one version line. Cost of the choice: about 230 MB more than the shell alone and a slower cold start (measure in the rebake). Decision D-A1.

aarch64 Linux (server hosts only; Freestyle is x86_64): no CfT build exists. Until the fork ships aarch64, the `browser` role on aarch64 reports `unavailable` with the reason. We do not fall back to a distribution Chromium (Ubuntu ships it only as a snap).

Disk delta for the default image: about 0.75 GB (Chrome, libraries, fonts, cmux-cua, display packages, ffmpeg). vm-image.md targets under 5 GB used; the proposed row is 4.88 GB. So the browser and CUA packages break that target unless the CJK fonts or ffmpeg move to a store package fetched on first use. Decision D-A2.

## 3. Display for CUA (on demand, owned by the session host)

- Owner: the session host (computer-use.md section 2, "headless displays on Linux/VMs"). The CUA host uses displays; it does not create them.
- Start: on the first `cua.*` op that needs a desktop app in a session. Xvfb runs as the work user: `Xvfb -displayfd <fd> -screen 0 <w>x<h>x24 -nolisten tcp -auth <state>/displays/<id>/Xauthority -s 0 -dpms`. `-displayfd` lets the X server choose a free display number, so there is no race. The Xauthority cookie is per display, mode 0600. openbox and a session D-Bus with the AT-SPI bus start in the same cgroup scope.
- Stop: at session end, and after an idle period with no `cua.*` op and no viewer (one-shot timer, no polling). A crash restarts it with `Backoff`; the CUA session gets `display_lost` and a new display.
- Per session or per machine: CLOUD-BROWSER-DISPLAY (2026-10-04) says per session; computer-use.md decision 6 (2026-10-02) says one per machine first because the X11 backend holds one connection. Proposal: the session host API is per session from the start (`display.acquire {session}` returns `{display, xauthority}`); while the X11 backend has one connection, the host maps every session to one shared display and records `display_shared: true`. When cmux-cua step i lands, the mapping changes, the API does not. Decision D-A3.
- Size: the viewer's pane size when a viewer is attached at start, else 1920x1080. Resize uses RandR, no restart.
- `cua-compositor` instead of Xvfb: behind a debug switch `cua.linux.display = xvfb | compositor` (DEV/NIGHTLY) once its build is pinned.

## 4. Browser host on Linux

- Engine path: browser host `CdpDriver<PipeTransport>` launches Chrome with `--remote-debugging-pipe` and `--headless` (Ozone headless). No display.
- User-visible Cloud tabs: RT8 says they are remote tabs. Until the remote presentation fork exists (RT r1, r2), a user who watches an agent's Cloud browser sees CLOUD-WATCH frames (`Page.startScreencast` through the browser host, push based) with the agent cursor drawn client side. That is a stop-gap, not the remote tab.
- Profiles: one user-data-dir per workspace profile under the work user's state dir, mode 0700 (browser-host.md, server.md section 10).
- Idle flags (finding 5): proposal to the browser host owner: keep `--disable-renderer-backgrounding` and the timer flags only while an agent lease is active on that tab, else launch without them, if the measurement in section 6 shows they cost idle CPU. Not changed in this run (cmux-tui/ is out of scope).

## 5. sshd for LINK-FILES

LINK-FILES: scp, sftp and rsync use the link `ssh` service with `cmux link` as ProxyCommand; the VM daemon forwards the stream to the local sshd; sshd accepts only short-lived OpenSSH user certificates from the team SSH CA (team-vm.md "SSH access").

Image side (baked, no key material):

```
# /etc/ssh/sshd_config.d/10-cmux.conf
ListenAddress 127.0.0.1
ListenAddress ::1
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile none
TrustedUserCAKeys /etc/cmux/ssh/user-ca.pub
AuthorizedPrincipalsFile /etc/cmux/ssh/principals/%u
RevokedKeys /etc/cmux/ssh/revoked.krl
AllowUsers cmux
```

- At bake: `user-ca.pub` and the principals file are empty, so nobody can log in. The smoke checks this.
- At bind: `cmux host` writes the CA public key, the principals for the work user and the KRL from the instance binding (control plane). The team VM uses `AuthorizedPrincipalsCommand` from the reconciler instead (team-vm.md); the image supports both by a drop-in that bind selects.
- Updates: a KRL or CA change arrives as an event on the link; `cmux host` rewrites the file atomically. sshd reads `RevokedKeys` per connection, so no reload is needed.
- Socket activation: Ubuntu 24.04 uses `ssh.socket`; its generator turns `ListenAddress` into the socket's listen list. UNVERIFIED on the Freestyle base; the rebake checks `ss -ltn` shows only loopback port 22.
- Host keys: per clone after bind (already done by the bind path; smoke `ssh-host-key-differs`).
- Gap: the CA for a personal (non-team) Cloud machine. cloud-client-contract.md 1.7 says "team SSH CA". A user without a team needs a CA too: proposal: every account has a personal team (if that is already the model) or `UserDO` issues with the same op shape. Decision D-A4, owner backend lead. spec-coverage.md:852 lists "SSH CA in TeamDO ... sshd trust" as NO OWNER; this lane takes the sshd half.

## 6. Per-session CPU and RAM budget, and the idle proof

### 6.1 cgroup layout (cgroup v2, delegated to `cmux host`; the guest has cpu, memory, io, pids and working delegation, vm-image.md 6.5)

```
cmux.service (Delegate=yes)
  host/                     cmux host, session host, browser host, cmux-cua serve
  terminals/                agent and shell processes (unchanged)
  automation/               MemoryMax = RAM - 1 GiB reserve
    browser-<session>/      one Chrome process tree
    display-<session>/      Xvfb, openbox, AT-SPI bus, apps that CUA launches
```

The session host writes cgroupfs directly (delegated subtree), no D-Bus round trip. Over budget is a typed error (`resource_exhausted {kind, limit}`), shown in the Agent activity pane, never an OOM kill of an unrelated process.

### 6.2 Budgets (targets; the first dev rebake measures and this table records the result)

| Limit | sm (2 vCPU, 4 GiB) | md (4 vCPU, 8 GiB) |
| --- | --- | --- |
| browser session `memory.high` / `memory.max` | 768 MiB / 1 GiB | 1 GiB / 1.5 GiB |
| browser session `cpu.max` | 150% | 200% |
| display session `memory.max` (incl. launched apps) | 1 GiB | 2 GiB |
| display session `cpu.max` | 100% | 200% |
| `pids.max` per session | 512 | 1024 |
| `cpu.weight` (terminals 100) | 50 | 50 |
| concurrent browser / display sessions | 2 / 1 | 4 / 2 |
| remote tab encode (RT r7) | not offered on sm until the bench (remote-tab.md section 11: 3 to 6 vCPU while scrolling, estimate) | 1 stream |

Every number is a setting under `cloud.automation.*` (default = this table), with a Debug Settings tunable in DEV and NIGHTLY.

### 6.3 Idle proof method (extends `images/cmux-vm/guest/sampler.py`)

1. Setup on a fresh clone: one browser session on a static `data:` page, one display session with one idle `xterm`, no viewer, no agent call. Wait 60 s.
2. Sample for 120 s: `cpu.stat usage_usec` delta per scope; `/proc/stat processes` delta; per-thread `voluntary_ctxt_switches` deltas for every pid in each scope (wakeups per second); `memory.current` and `memory.peak`.
3. Pass: no process created; display scope under 0.01 CPU-s/min; browser scope under 0.1 CPU-s/min (target, Chrome has internal timers; record the measured value and per-thread wakeups so regressions are visible); machine total within vm-image.md 4.8 budget (0.2 CPU-s/min) plus the two scopes.
4. Demand stop: end both sessions, wait for the idle timers, then assert no Chrome, Xvfb, openbox or `cmux-cua` process exists and the machine is back at the baseline row.
5. A/B for finding 5: the same run with and without the three background flags.

## 7. Sandbox (never `--no-sandbox`)

- Chrome: namespace sandbox (unprivileged user namespaces) plus seccomp-BPF. We do not install the SUID `chrome-sandbox` helper (no setuid binary added). Chrome runs as the work user, never root.
- The browser host refuses to launch when `extra_args` contains `--no-sandbox`, `--disable-seccomp-filter-sandbox` or `--disable-namespace-sandbox` (request to the browser host owner; unit test first).
- Where user namespaces are blocked (Ubuntu 23.10+ AppArmor on server hosts), system mode installs the AppArmor profile from server.md section 10; user mode reports the `browser` role `unavailable` with the one `sudo` command.
- Smoke proof: the browser host opens `chrome://sandbox` over CDP and the check requires "Namespace Sandbox: Yes", "Seccomp-BPF sandbox: Yes" and "You are adequately sandboxed."; plus `/proc/<renderer>/status` `Seccomp: 2` and distinct `user`, `pid`, `net` namespace links (the prototype's method).
- Display: `-nolisten tcp`, per-display cookie, no `xhost`. Other users on the machine cannot connect.
- cmux-cua: runs as the work user; socket 0600 in a 0700 dir; launch credential from the session host (computer-use.md).
- Known residual risk: every session of one user shares one uid, so a compromised Chrome renderer that escapes the sandbox reaches the user's files. Per-session uids are out of scope here.

## 8. Smoke additions (gate in `smoke.ts`, every bake)

- `browser`: start the browser host, open a session, navigate a `data:` page, evaluate JS, take a screenshot; sandbox checks of section 7; cold start time (create to first CDP reply).
- `cua`: acquire a display, start `xterm`, `cmux-cua` list windows, click and type into it, read text back through AT-SPI or the screen; release; assert the display process is gone.
- `ssh`: sshd listens on loopback only; with an empty CA a cert login fails; with a throwaway CA generated on the runner for this run only (written through the bind path, never baked) `ssh -o CertificateFile ... cmux@127.0.0.1 true` passes and `scp` of 1 MiB round trips. The throwaway CA private key never leaves the runner.
- Idle proof of section 6.3.
- Secret scan: also refuses any `*.pub` under `/etc/cmux/ssh` at bake.

## 9. Hosted Linux CI job (proposal; not written as a workflow in this run)

Name `cloud-automation-linux.yml`, "Cloud automation (Linux, not a gate)". Non-required (not in the ruleset list in scripts/ci/required_status_checks.py). Path filter: `cmux-tui/crates/cmux-browser-host/**`, `images/cmux-vm/**`, `web/scripts/cmux-vm-image/**`, the workflow file. Triggers: pull_request and push to feat-cmux-next with those paths, plus dispatch. `timeout-minutes: 5`. Template: `automation-bench.yml`.

Steps:
1. apt install `xvfb xauth openbox at-spi2-core dbus-user-session xterm` (about 30 s on the Blacksmith runner, estimate).
2. Download pinned CfT `chrome` (sha256 from `inputs.lock.json`, the same pin as the image) and the pinned `cmux-browser-host` and `cmux-cua` Linux binaries from files.cmux.com (sha256 checked).
3. Browser host test: run the existing `browser_host_drives_headless_chromium_over_the_pipe` scenario through the prebuilt binary's `eval` verb against CfT, sandbox on, plus the `chrome://sandbox` check.
4. In `xvfb-run -a dbus-run-session`: start openbox and `xterm`; `cmux-cua serve`; list windows, click, type `echo cua-ok`, screenshot, read back; also launch CfT headful in the display and click a button in a local page (proves Chrome works as a desktop app under CUA).
5. Upload screenshots and logs.

Why not written now: steps 2 and 3 need prebuilt binaries that do not exist (findings 4 and 6). Building `cmux-browser-host` with cargo on the runner does not fit 5 minutes (the existing `cdp-browser-smoke` job allows 25). Prerequisites:
- P1. `cmux-tui-artifacts.yml` publishes `cmux-browser-host` (or the `cmux` binary gains `browser host`, #16174). Owner: browser host owner; a workflow change, no cmux-tui/ code.
- P2. A manaflow-ai/cmux-cua Linux release (`cua-driver-rs-v<ver>`) from the cmux-cua-native line, x86_64 and aarch64, with sha256 and attestation. Owner: computer use lead.
- P3. A CfT pin in `inputs.lock.json` (this lane, first dev rebake).

Promotion to required only after one green week and the coordinator's OK (same rule as remote-tab.md section 9).

## 10. First dev-only rebake (proposed; not run in this run)

- Name: `cmuxnp-dev-vmimg-auto1-<sha10>` (enforced by `lock.ts` and `guest.ts`). Account: cmux-next dev key (`~/.secrets/freestyle-cmux-next-dev-20261004.key`, passed by path through the new `--api-key-file`). No production snapshot, no manifest change, no default switch (V3).
- Lock changes: Chrome runtime libraries, fonts, display packages, ffmpeg (or not, D-A5); `programs`: CfT `chrome` (stage A), `cmux-browser-host`, `cmux-cua` (after P1, P2; if they are not ready, bake the packages and the sshd config without them and record that); `roles` filled.
- Recipe changes: sshd drop-in and empty CA files (section 5); `cmux.service` `Delegate=yes`; Xauthority dir; no unit enabled at boot except what exists today.
- Smoke: today's checks plus section 8.
- Measure and record here: disk delta, bake time delta, create-to-daemon-listening p50/p95 against the 2026-10-02 rows (must not regress; the roles are off), Chrome cold start, display start time, section 6.3 idle numbers, sandbox status.
- Cleanup: the ledger deletes every VM and the snapshot by id at the end, also on failure. Nothing outside this run's ledger is touched.
- Duration estimate: bake about 2 min (66 s today plus about 60 s of packages), smoke with 5 clones about 5 min.

## 11. Migration list: plan lines that say chrome-headless-shell for user-visible tabs

Proposed edits only. Each line belongs to another lane or to the spec; the owner or the coordinator applies them.

| File:line | Today | Proposed text | Owner |
| --- | --- | --- | --- |
| plans/cmux-next/server.md:48 | `browser   cmux browser host + chrome-headless-shell (pipe, sandboxed)` | `browser   cmux browser host + Chrome (pipe, Ozone headless, sandboxed); remote tabs through remote-browser (RT8)` | server lead |
| plans/cmux-next/server.md:121 | `` `browser` `` = `cmux browser host` + chrome-headless-shell | `cmux browser host` + pinned Chrome (CfT, then the fork, cloud-automation.md 2.2); `remote-browser` row added | server lead |
| plans/cmux-next/server.md:396 | browser host with `chrome-headless-shell` from the store | pinned Chrome from the store; AppArmor profile path changes to the `chrome` binary; user-visible tabs are remote tabs (RT8) | server lead |
| plans/cmux-next/server.md:481 | chrome-headless-shell needs its shared libraries bundled for user mode | the Chrome engine needs its shared libraries bundled for user mode (list in cloud-automation.md 2.2) | server lead |
| spec/plan-server.md:49, :122, :397, :482 | same as above | same as above | coordinator |
| spec/browser-use.md:69 | Chrome for Testing or `chrome-headless-shell` | Chrome (CfT, then the fork) with `--remote-debugging-pipe`; user-visible Cloud tabs are remote tabs (RT8) | coordinator |
| spec research/browser-use.md:156 | headless Chromium (Chrome for Testing or `chrome-headless-shell`) | historical research; add a note pointing to RT8, no rewrite | coordinator |
| decisions.md:665 CLOUD-BROWSER-DISPLAY | per-session display shared by browser and CUA | already superseded for the browser by RT8; add "see RT8" so readers do not build a display for the browser | coordinator |
| plans/cmux-next/computer-use.md:188 and decision 6 | one Xvfb per machine at `:90` | per-session API, shared display while X11 holds one connection (section 3, D-A3) | computer use lead |
| plans/cmux-next/vm-image.md:93 | desktop package = VNC, Chrome, Ghostty, window manager, cua-driver | Chrome moves to the `browser` role, cua-driver becomes pinned `cmux-cua` in `cua`; desktop keeps VNC and the window manager on the shared display supervisor | this lane (vm-image.md is adopted; edit with the first rebake) |
| server/prototype/linux/README.md:18, :139 | prototype measured chrome-headless-shell | keep (measured history); the rebake re-measures with Chrome | none |

Not migrated: remote-tab.md:16 and :156 already state the RT8 rule.

## 12. Decisions needed (through the coordinator)

- D-A1. Ship only full Chrome (no chrome-headless-shell) on Cloud and server Linux. Recommendation: yes.
- D-A2. Disk target: accept about 5.6 GB used for the default image, or move CJK fonts and ffmpeg to on-first-use store packages. Recommendation: on-first-use for CJK fonts and ffmpeg.
- D-A3. Display: per-session API with a shared display until cmux-cua supports several X connections. Recommendation: yes.
- D-A4. SSH CA for personal (non-team) Cloud machines. Recommendation: same op shape, issued by the account's owner object; backend lead decides.
- D-A5. Linux CUA video: ffmpeg in the image, on first use, or frames only.
- D-A6. Remote tab encoder license on Linux (x264 GPL versus openh264 Cisco binary download). Needed before RT r2.
- D-A7. CI key move: a new environment with the cmux-next dev key for `cloud-vm-image-bake.yml`. Needs a repo admin.

## 13. Next windows and slots requested

1. Image pipeline slot (this lane): edit `images/cmux-vm/**` and `web/scripts/cmux-vm-image/**` (lock, `--api-key-file`, sshd drop-in, smoke additions, roles). No cmux-tui/ change.
2. A Freestyle dev window on the cmux-next dev account for the first rebake (section 10): one builder VM, one snapshot, five smoke clones, all `cmuxnp-dev-vmimg-auto1-*`, deleted by ledger at the end. About 10 minutes.
3. Repo admin action (Lawrence): the `cmux-next-vm-image-dev` environment secret (D-A7).
4. Browser host owner: P1 (publish the binary), the `--no-sandbox` refusal, and the idle flag A/B (cmux-tui crate slot, theirs).
5. Computer use lead: P2 (cmux-cua Linux release in manaflow-ai/cmux-cua).
6. Session host owner: display supervisor and delegated cgroups (cmux-tui window; Cargo.lock change unknown until designed).
7. After 1, 2 and P1 to P3: write `cloud-automation-linux.yml` (section 9).

## 14. Decisions recorded (CLOUD-AUTOMATION, coordinator 2026-10-04)

D-A1 the fork's Chrome-style build is the engine; Chrome for Testing x86_64 is the interim. D-A2 CJK fonts in the image; ffmpeg and heavy tools are first-use role packages. D-A3 per-session display API on one shared display until cmux-cua has one X11 connection per display. D-A4 per-user SSH CA for personal machines, team CA for team machines. D-A5 ffmpeg on first use. D-A6 x264 with openh264 fallback. D-A7 the rotation lead creates environment `cmux-next-vm-image-dev` with only the cmux-next dev key; no bake before the coordinator confirms it. Bakes stay `workflow_dispatch` only; `cloud-vm-image-lock.yml` runs the lock and sshd tests on path changes.

## 15. Image changes landed (no bake yet)

- Lock (`images/cmux-vm/inputs.lock.json`): 31 new baked Ubuntu packages (42 total): the display role (`xvfb`, `xauth`, `at-spi2-core`, `libxtst6`, `libxi6`; `dbus-user-session` is already in the base) and `fonts-noto-cjk`. About 97 MB installed. `roles`: `fonts` on, `display` off, `display-wm` and `cua-video` off and first-use. `apt.ubuntu.firstUse`: `display-wm` (openbox, 64 packages, about 92 MB) and `cua-video` (ffmpeg, 138 packages, about 161 MB), never baked.
- Deviation from section 2.2: openbox is first use, not baked. openbox pulls Ghostscript, CUPS libraries and poppler (+64 packages). That is every image paying 92 MB and their CVE surface for a window manager that only CUA on desktop apps needs. cmux-cua's Linux e2e tests openbox, so the window manager stays openbox; only the delivery changes. Cost: the first display start on a machine waits for one apt install from the dated snapshot (estimate 10 to 20 s, measure in the dev bake).
- How the closures were made: an amd64 `ubuntu:24.04` container with the locked snapshot mirror and a synthetic dpkg status built from the Freestyle base dpkg list whose sha256 equals the lock fingerprint (`d29cfb5c…`, 415 packages, all records found in the snapshot). The same simulation reproduces today's 11-package closure exactly. The bake's `aptClosureProblems` still checks the real install. Script and outputs: `.cmux-scratch/nx-cloud-automation/closure/` in hq.
- First-use install contract for `cmux host`: `/etc/cmux/roles.json` (schema 1) lists each role's default, first-use flag, top-level apt names and the exact first-use closure, plus the snapshot URI. After the bake, apt sources point at the live archive, so the first-use installer must read the snapshot source explicitly (`-o Dir::Etc::sourcelist=`). Risk: a user who upgraded a shared library from the live archive can make a pinned closure fail; the installer then reports `role_unavailable {reason: apt_conflict}`, never installs unpinned versions.
- sshd (section 5, D-A4): `/etc/ssh/sshd_config.d/10-cmux.conf`, empty `/etc/cmux/ssh/user-ca.pub` and principals file, an empty KRL, `ssh.socket` enabled when nothing else is. The bake fails unless `sshd -T` matches the policy and `ss` shows port 22 on loopback only. The smoke, on a clone only, proves: empty CA refuses; a throwaway CA written the way bind will write it allows a certificate login and an scp round trip; a plain key is refused; a KRL entry by key id refuses the certificate. The bind side (writing the CA, principals and KRL from the instance binding) belongs to the bind agent.
- cmux-cua: `OPTIONAL_PROGRAMS = ["cmux-cua"]` and `cmuxCuaReleaseShape(version, arch)` give the lock entry shape for the release contract (tarball with LICENSE, `bin` `cmux-cua-<V>-linux-<arch>/cmux-cua`, role `cua`). It is pinned only from a published release.
- Risk: Freestyle's own SSH gateway, if anything uses it with this image, stops working, because sshd listens on loopback only and `AuthorizedKeysFile none`. The bake and smoke use the exec API, not SSH.

## 16. Session host design: display supervisor and per-session cgroups

Owner: the session host (cmux-tui daemon). Code home: a module family in `cmux-tui-core` (`automation/display.rs`, `automation/cgroup.rs`, `automation/budget.rs`), no new crate and no new dependency (`libc` is already a dependency), so no Cargo.lock change. The CUA host and the browser host consume it through ops; they never spawn displays or write cgroups.

Entities and single writers:

| Entity | Writer | Readers |
| --- | --- | --- |
| `display_lease {id, session, display, xauthority, shared, size, state}` | session host | CUA host (through `display.acquire` result), Agent activity pane |
| display process set (Xvfb, first-use openbox, AT-SPI bus) | session host | none |
| cgroup subtree `automation/` and its children | session host (delegated, `Delegate=yes`) | none; budget values come from settings |
| budget settings `cloud.automation.*` | user and team policy (settings store) | session host |

Ops (catalog owner `session-host`, origin rules per OWNERSHIP-PRINCIPLES):

- `display.acquire {session, size?, idempotency_key}` -> `{lease, display, xauthority, shared}`. Caller: the CUA host on the first `cua.*` op that targets a desktop app. Starts the display when none runs: first-use install of `display-wm` if needed (role state `installing`), Xvfb with `-displayfd` (no race for a number), `-nolisten tcp`, `-auth <state>/displays/<id>/Xauthority` (0600), `-s 0 -dpms`; then openbox and a session D-Bus with the AT-SPI bus, all in `automation/display-<id>/`. Ready = the display number arrives on the `-displayfd` pipe (an event, not a poll). While cmux-cua holds one X11 connection (D-A3), every acquire maps to the one shared display and returns `shared: true`.
- `display.release {lease}`. The last release arms a one-shot idle timer (`cloud.automation.displayIdleSeconds`, default 120). The timer stops the process set and removes the cgroup. A new acquire before it fires cancels it.
- `display.list` and the `display.changed` event for the Agent activity pane.
- Crash: a child exit is a pidfd event. The supervisor marks the lease `lost`, emits `display.changed`, restarts with `Backoff` only while a lease exists, and the CUA host gets `display_lost` and re-acquires.
- `automation.scope.create {kind: browser|display, session}` (internal to the daemon for the browser host and the display path): makes `automation/<kind>-<session>/`, writes `memory.high`, `memory.max`, `cpu.max`, `cpu.weight`, `pids.max` from the budget table (section 6.2), then the child is spawned into it with `clone3(CLONE_INTO_CGROUP)` (or by writing its pid to `cgroup.procs` before exec where clone3 is not available). Over budget at create = `resource_exhausted {kind, limit}`. A `memory.events` `oom_kill` increment is read on the cgroup's inotify event (`cgroup.events`/`memory.events` modify), never by polling, and becomes a `resource_exhausted` event for that session.

Pure reducer (tests first, property tests): state = leases, process sets, scopes, timers; inputs = acquire, release, child exit, ready, timer fired, install done or failed; outputs = spawn, kill, write cgroup, arm or cancel timer, emit. Invariants: at most one display process set while `shared`; no process set without a lease or an armed idle timer; a scope exists exactly while its process set does; no restart without a lease; every acquire gets exactly one answer.

User mode (servers without root): the systemd user manager delegates `user@<uid>.service`; the same code writes the delegated subtree. Where delegation is missing, scopes are skipped and the health role reports `budget.unenforced` (warning), never a silent pass.

Tests: reducer unit and property tests (Testbox, `cargo test -p cmux-tui-core automation::`); a Linux integration test in the hosted cmux-tui workflow with Xvfb installed (acquire, ready by displayfd, release, idle stop, crash restart, cgroup files written in a delegated test subtree); the dev-bake smoke runs the section 6.3 idle proof.

Window request: one cmux-tui window for `cmux-tui-core` (new module family, catalog entries for `display.*`, the daemon wiring). No Cargo.lock or Cargo.toml change. It may touch the protocol spec JSON (new ops), which needs a window under WINDOW-LITE.

## 17. VM agent (bind, status report, events)

Interim implementation: `images/cmux-vm/guest/vm-agent.ts`, a Bun program (the base keeps the real bun at `/usr/local/bin/bun`), no npm dependency. vm-image.md places the bind agent in the Rust `cmux host` role; this is the stand-in until that role exists, with the same contract, so the port is a translation with the same tests.

- Trigger: `cmux-vm-agent.path` (`PathExists=/var/lib/cmux/bind.json`) starts `cmux-vm-agent.service`; the service is also enabled at boot with `ConditionPathExists=|bind.json` or `|bound.json`. While it runs, a directory watch (inotify) catches a new bind.json. No polling. The bake arms the path unit and checks the service is not running at snapshot time.
- Bind: refuses an `api_origin` that is not the environment's allowlisted origin (dev `cmux-api-development.debussy.workers.dev`, stg `cloud-api-staging.cmux.dev`, prod `cloud-api.cmux.dev`); per-clone ES256 P-256 install key in `/var/lib/cmux/install/key.json` (0600, replaced when the MMDS instance id differs; one MMDS read per bind); per-clone WireGuard key in `/var/lib/cmux/wg/key.json`; POST `/v1/cloud/bind`; writes `bound.json` before removing `bind.json`. A 4xx is final (token spent or invalid), a 5xx or network error retries with backoff.
- Tokens: `/v1/auth/challenge` then `/v1/auth/token`; signs only when `message_prefix` equals `cmux-auth-v1\n<ENVIRONMENT>\n<install>\n` for this machine's environment.
- `cloud.vm.status.report` (backend 8feb7efab5a: 24 h without an applied report pauses the machine): one report after bind and at every service start; on change from the local socket, at most 1 per 10 s, latest wins; a heartbeat deadline 1 h after the last accepted report (one timer, re-armed); failures back off from 5 s, doubling, ±10% jitter, at least `retry_after_ms`, at most 10 min; while a retry is pending the heartbeat timer is cancelled, so a failing machine holds one timer.
- `cloud.vm.event.emit`: v1 kinds and the 4 KB limit checked locally; `cloud.rate_limited` waits `retry_after_ms`; an invalid event is dropped and logged.
- Local socket `/run/cmux/vm-agent.sock` (root and group `cmux`, 0660): JSON lines `{"activity": {...}}` or `{"event": {...}}`.
- Tests: `web/tests/vm-image-vm-agent.test.ts` (11) against a fake server that answers from `backend/catalog/cloud-vectors.json` and verifies the ES256 signature the way the backend does.

Gaps (not hidden):
- Activity feeder: nothing writes to the socket yet. Until the daemon or its hooks send activity, reports carry `active_sessions: 0` and no timestamps, so CloudDO's idle pause can pause a machine a person is using after its idle period. The feeder is a cmux-tui change (session open/close, user input, agent action -> one socket line); it needs a cmux-tui window.
- Resume detection: a resume without a new bind.json is caught only when the heartbeat deadline fires (monotonic timers count paused time, vm-image.md 6.5, so an overdue deadline fires at resume). The exact signal (timerfd `TFD_TIMER_CANCEL_ON_SET`, vm-image.md 6.2) belongs to the Rust port.
- Daemon capabilities: read from `/etc/cmux/daemon.json` when present; the bake does not write it yet, so bind sends the pinned cmux-tui commit and an empty capability list. Next bake: record the daemon's `identify` capabilities into that file.
- Live proof against the development API is the dev bake's one-clone smoke (section 10), not run yet.

## 18. Machine size research (goal 3)

Facts from the Freestyle SDK 0.2.10 type docs (`web/node_modules/freestyle/dist/vms/types.d.ts`, `index.d.ts`) and the classic size ladder code, which already depends on them in production (`web/scripts/derive-devbox-sizes.ts`, its post-derive check boots every derived snapshot and verifies nproc, memory and root filesystem):

1. A snapshot keeps its source VM's size. `vms.create` takes no resources; a VM boots at its snapshot's vCPU, memory and disk. The backend driver says the same (`backend/apps/api/src/cloud-driver.ts` `createBody`: "the snapshot decides; resize is a separate, grow-only call").
2. Smallest bake base: `freestyle/ubuntu-sm` (2 vCPU, 4 GiB, 16 GB). The only smaller catalog base is `freestyle/busybox` (1 vCPU, 128 MiB, 1 GB), which is not Ubuntu and cannot carry the image. Nothing shrinks (resize is grow-only on every axis), so the bake must stay on `ubuntu-sm`, and the image must fit 16 GB (today about 5 GB used).
3. Resize after create: `vm.resize({cpu, memory, storage})`, every axis grow-only; vCPU and memory apply live to a running VM, on resume for a paused one and at the next boot for a stopped one; disk grows only while the VM runs, in place (the derive script waits up to 60 s for the root filesystem to show it).

Options for sizes above sm in cmux-next:
- A. Derived ladder (as classic): one snapshot per size from each bake (about 30 s, parallel). Boots straight into its shape. Cost: 6 snapshots per bake, 6 smoke targets, 6 rows to promote and roll back.
- B. Resize after create: one snapshot (sm); the driver calls `resize` right after `vms.create`, before the bind agent's first report. Cost: create-to-ready grows by the resize call plus the disk-growth wait, and a resize failure becomes a create failure path.

Recommendation: B if the dev bake's resize probe shows the guest sees the new shape within about 2 s; else A. Strongest objection to B: a resize on the create critical path couples machine readiness to a second provider call that can fail or be slow under provider load (the classic 9 s create outliers). The probe (`smoke.ts --resize-probe`) records the call time and the time until the guest sees 4 vCPU, 8 GiB and a 32 GB root filesystem. Decision after the numbers; the backend driver change (send the resize) belongs to the backend lead.

## 19. First dev bake (2026-10-05, cmux-next dev account)

How it ran: `workflow_dispatch` needs the workflow file on the default branch, and `cloud-vm-image-bake.yml` exists only on feat-cmux-next, so CI cannot dispatch it. The bake and smoke ran from this lane's worktree at 8d111c84246 with `FREESTYLE_API_KEY_FILE` pointing at the cmux-next dev key (read in process, never printed). Same scripts, same names, same ledger.

| Item | Value |
| --- | --- |
| Snapshot (kept, dev channel) | `cmuxnp-dev-vmimg-auto1-8d111c8` = `sh-99d84130836649b4b1b746a41f57b5f9` (`images/cmux-vm/channels/dev.json`) |
| Bake | 164.5 s; snapshot call 751 ms; 47 apt packages installed, equal to the lock (42 Ubuntu + 5 PGDG), so the container-computed closure held on the real base |
| Size | sm (2 vCPU, 4 GiB, 16 GB); root fs used 4.91 GB, 114,593 inodes; store 1.16 GB |
| Boot, 2 clones x 2 runs | create API 164 to 243 ms; create to first exec p50 194 to 196 ms; create to daemon listening p50 567 to 574 ms; create to ready p50 650 to 668 ms |
| Idle CPU (whole VM, 90 s) | 2.47 and 2.63 CPU-s/min: today's `cmux-devbox-boot` 1 s metadata poll dominates; the 0.2 target needs `cmux host run` (vm-image.md step 2). Terminal hosts: 0 voluntary switches in 60 s |
| sshd | policy and loopback-only listen: PASS; empty CA refuses, certificate login, scp 1 MiB, plain key refused, KRL-revoked certificate refused: PASS (second smoke; the first smoke's plain-key step was a test bug: the client loads `<key>-cert.pub` by itself) |
| Roles | display packages present and not running, openbox and ffmpeg absent, CJK fonts present: PASS |
| VM agent | bind probe against the development API: path unit started the agent, per-clone keys 0600, API answered `auth.forbidden` for the never-issued token, bind.json removed, no bound.json: PASS |
| Resize sm -> md | call 197 to 208 ms; guest sees 4 vCPU, 8,011 MiB, 32,078 MiB root 1,346 to 1,378 ms after the call started |
| Resources | 1 failed bake builder (103 s, fc-list check, deleted), 1 bake builder (164 s, deleted), 4 smoke clones (135 to 138 s each, deleted), 1 snapshot kept. 812.5 VM-seconds at sm (13.5 VM-min, 27 vCPU-min). Dollar cost UNVERIFIED (no rate card in the repo). Wall clock 08:30:47 to 08:42:17 UTC (11.5 min, over the approved 10 min by 1.5 min) |

Size decision input (section 18): the resize probe is under 2 s, so option B (one sm snapshot, resize right after create) is the recommendation.

Not done in this window:
- The one-clone end-to-end against the development API (real bind, applied status report, minted token). It needs (1) the development Worker's `CLOUD_FREESTYLE_SNAPSHOT` set to `cmuxnp-dev-vmimg-auto1-8d111c8` (backend lead; the prefix check accepts it) and (2) a dev identity in the allowed team to call `cloud.machine.create` (the driver then writes bind.json with a real one-time token). Neither is this lane's to set.
- cmux-cua 0.8.2 and `libxkbcommon0` were pinned after this bake (`cmux-cua --version` verified in an amd64 Ubuntu 24.04 container with libX11, libXi and libxkbcommon), so this snapshot does not carry them. The next bake does. The release tarball has no LICENSE file, against the release contract (CI lead).

## 20. Fixes before the rebake (coordinator 2026-10-05)

- Per-clone machine-id: the agent regenerates `/etc/machine-id` and `/var/lib/dbus/machine-id` (0444) when the MMDS instance id differs from `/var/lib/cmux/machine-id.instance`, in the same bind path that rotates the install key. Services that read the id at boot (journald) keep the old one until they restart; the rebake measures whether that matters.
- Real daemon block in bind and status reports: the agent sends `identify` on the daemon's control socket (path recorded by the bake from `ss`, `/etc/cmux/daemon-socket`). `version` = daemon version + `+` + build commit (12). The daemon advertises about 70 capabilities and bind accepts at most 32, so `capabilities` = the Cloud-gated ones it advertises (`fs-v1`, `loopback-forward-v1`) + `vm-agent-v1` + `activity` only when an activity sender exists (`ACTIVITY_SENDER_EXISTS = false` today), so the backend can skip idle pause for machines without activity. Fallback: the bake's live identify recorded in `/etc/cmux/daemon.json`; the bake fails if that is not a real answer. Never an empty list.
- Agent socket moved to `/run/cmux-vm-agent/agent.sock`: the bake's park step and the boot supervisor clear `/run/cmux`.
- cmux-cua: no release qualifies. 0.8.2, 0.8.3 and 0.8.4 are all pre-releases, and none of their Linux tarballs contains LICENSE (checked 2026-10-05). The 0.8.2 pin is removed; `libxkbcommon0` stays baked for it. Routed to the CI lead through the coordinator.

## 21. Blocker: idle CPU target (0.2 CPU-s/min)

Measured 2.47 and 2.63 CPU-s/min (whole VM, 90 s, section 19). The cause is the classic boot supervisor `cmux-devbox-boot`, which this image still uses: a 1 s loop with two metadata-service `curl` calls (vm-image.md section 3: about 2 CPU-s/min and 354 forks per minute). Terminal hosts are idle (0 voluntary switches in 60 s). Fix: `cmux host run` (vm-image.md step 2, a role of the Rust `cmux` binary): event-driven bind on the resume signals of vm-image.md 6.2, no metadata poll. It needs a cmux-tui window and the session host owner. Until then no bake can meet the 0-idle target; the smoke records the number and does not gate on it.

## 22. Second dev window (2026-10-05 10:17:21 to 10:24:58 UTC, 7.6 min)

Operator bakes (vm-image.md 4.11 command), cmux-next dev account.

| Run | Result |
| --- | --- |
| `cmuxnp-dev-vmimg-auto2-4fd4596` | bake failed at `daemon-identify-record` (my check was too strict). The live identify worked: `0.1.0+d7f8fd06326f`, capabilities `["vm-agent-v1"]`. The pinned cmux-tui d7f8fd06 advertises neither `fs-v1` (only on a bound Cloud host) nor `loopback-forward-v1`. Builder deleted. |
| `cmuxnp-dev-vmimg-auto2-584940e` = `sh-291ed5654cab4bdbac8273932564b7f2` | bake passed in 169.8 s. Smoke: every check passed except `vm-agent-bind-probe`, which failed with no output. The snapshot was deleted by the ledger (no snapshot is kept after a failed smoke). Dev channel stays `auto1-8d111c8`. |

Smoke numbers of the second bake: create to first exec p50 189 ms; create to daemon listening p50 548 ms (p95 1,190 ms, n = 2); idle 2.47 CPU-s/min (section 21); resize sm to md: call 185 ms, guest view 1,325 ms; sshd certificate checks all PASS.

Cause of the probe failure (inferred, not proven on a VM): after the agent writes a new `/etc/machine-id`, `journalctl` reads `/var/log/journal/<new id>` while journald still writes under the old id, so both journal greps in the probe found nothing and `set -e` exited silently. Fixes: the agent restarts `systemd-journald` after it changes the machine-id (dbus-daemon keeps the old id until its next start); the probe reads with `journalctl -m` and every step prints its own FAIL label. Next window: one bake and one smoke.

Pinned cmux-tui d7f8fd06 lacks `loopback-forward-v1`, so Cloud ports (first-party-apps/cloud/server ports/loopback.rs) refuse on this image until the lock pins a newer published cmux-tui.

Resources this window: 2 builders (111 s, 170 s), 2 smoke clones (136 s, 135 s), 1 snapshot (deleted). 552 VM-seconds at sm (9.2 VM-min).

## 23. Third dev window (2026-10-05 10:42:35 to 10:47:39 UTC, 5.1 min): dev channel

Baked from the pushed head 1526e7816e9 with the operator command. cmux-tui pinned to 4fd459691fe0 (published at files.cmux.com/cmux-tui/4fd459691fe0b69d69e73d48035983e7ffe7f3fa/, binaries checked against its manifest): it advertises `loopback-forward-v1`; the old main pin d7f8fd06 did not.

| Item | Value |
| --- | --- |
| Snapshot (dev channel, `images/cmux-vm/channels/dev.json`) | `cmuxnp-dev-vmimg-auto3-1526e78` = `sh-6d6e1173d5a94684b9b5b4ab5891f441` |
| Bake | 161.9 s; 48 apt packages = the lock (43 Ubuntu + 5 PGDG); root fs 4.94 GB; store 1.19 GB |
| Daemon block recorded at bake (live identify) | `0.1.0+4fd459691fe0`, `["loopback-forward-v1", "vm-agent-v1"]` |
| Smoke | PASSED, every check: boot p50 create to first exec 168 ms, to daemon listening 578 ms, to ready 649 ms; sshd certificate checks; roles off and fonts on; agent bind probe with every named step, including `machine-id-changed`, `machine-id-dbus-equal` and `journal-machine-id-line` (the journald restart works on a real clone); resize sm to md 172 ms call, 1,280 ms guest view; idle 2.49 CPU-s/min (section 21 blocker) |
| Resources | 1 builder (162 s), 2 clones (136 s, 135 s), all deleted; 1 snapshot kept. 433 VM-seconds at sm (7.2 VM-min) |

End to end against the development API: next, after the backend sets `CLOUD_FREESTYLE_SNAPSHOT` and hands over a dev identity. Sequence: `cloud.machine.create` -> bind (bound.json, install registered) -> first `cloud.vm.status.report` applied -> token minted (challenge + token) -> change report (activity line on the agent socket) -> heartbeat on a test interval (`CMUX_VM_AGENT_HEARTBEAT_MS` test override, to add) -> `cloud.machine.pause` -> `cloud.machine.start` -> report after start.

## 24. Fourth window and the first development end to end (2026-10-05)

Fourth window (23:44:23 to 23:50:07 UTC, 5.7 min): bake from the pushed head 71d9a472c2f, `cmuxnp-dev-vmimg-auto4-71d9a47` = `sh-e4aab9ea589146abb98e356574ffe2de`, 181.9 s, 48 apt packages = lock, root fs 4.97 GB. It carries cmux-cua 0.8.7 (store entry 26 MB; `programs-run` ran 12 commands) and the dev-only heartbeat override. Smoke PASSED (2 clones). Kept. The resize probe took 21.2 s for the call this time (172 to 208 ms in the three earlier windows): provider variance on the create critical path is real, which weakens option B of section 18 (resize after create). Option A (derived sizes) stays the fallback; decide after more samples.

End to end through the development API (`scripts/cmux-next/cloud-dev-e2e.sh`, development only, refuses other origins; Worker image `auto3-1526e78`), run 2026-10-05T23:54:19Z, all steps PASS:

| Step | ms | Result |
| --- | --- | --- |
| Stack sign-in (dogfood account) | 595 | session |
| user.ensure | 1,878 | user_57873416b63e10546f1f |
| cloud.machine.create | 1,875 | vm_1176120e606b07dcb20d, provisioning |
| bound (running, host set) | 1,721 | host_0658289e81d8a0aded5a, daemon 0.1.0+4fd459691fe0 |
| VM agent evidence | 144 | journal: machine-id regenerated, `bind: bound`; bound.json and install key 0600; machine-id marker = this clone's MMDS id |
| install.register (cli, ES256 key made by the script) + challenge + token | 243 | inst_2c5567287fcec53625c3, token minted |
| connect_info | 99 | host, epoch 1, running, services daemon+ssh, daemon block `0.1.0+4fd459691fe0` with `loopback-forward-v1`, `vm-agent-v1` |
| link_token (daemon) | 78 | minted, epoch 1 |
| pause | 353 | paused |
| start | 275 | running |
| VM after start | 75 | agent active |
| delete (by this run's id) | 263 | deleted; the provider VM `cmuxnp-dev-cld-vm-1176120e606b07dcb20d` answers not found |

Not yet proven, and why:
- First report applied, change report, heartbeat: the API shows a report only when the daemon block changes, so the evidence is the agent's own log. The agent now logs every report result (`report <reason> applied|held|failed`) and writes `/run/cmux-vm-agent/state.json`; the e2e runs these steps when the snapshot's agent logs results (auto5 or later), else it records them as SKIPPED.
- Report after start: a pause and start resumes the agent from memory (no boot, same instance id), so the agent did not report on resume. Fix: `cmux-vm-agent-resume.timer` with `OnClockChange=yes` (the provider sets the clock on resume) runs `vm-agent.ts --notify-resume`, which makes the running agent report with reason `resume`. Proven only in unit tests until auto5.
- Idle pause: the backend acts only on reports whose daemon block has `activity` and that carry activity times. No activity sender exists yet, so the agent does not advertise `activity`; the idle-pause step is blocked on the activity feeder (cmux-tui window, section 17).
- `cmux link dial` to the daemon: needs a darwin `cmux` binary with the link role on the operator Mac; the e2e stops at link_token.

## 25. Left in this plan

1. Fifth window: bake with report logging and the resume timer (auto5), smoke, then the backend switches development to auto5 and the e2e runs every report step.
2. Activity feeder (daemon or hooks -> agent socket) and then the `activity` capability (cmux-tui window).
3. `cmux host run` replacing `cmux-devbox-boot` (idle-CPU blocker, section 21; cmux-tui window).
4. Session host display supervisor and per-session cgroups (section 16; cmux-tui window).
5. Browser role: publish `cmux-browser-host`, pin Chrome for Testing, `--no-sandbox` refusal in the host, idle-flag A/B (section 4, 9).
6. Hosted Linux CI job (section 9) after P1 to P3.
7. Size decision A or B (section 18), with more resize samples.
8. `cmux link dial` leg of the e2e.
9. Delete `cmuxnp-dev-vmimg-auto1-8d111c8` only after the coordinator's OK (rollback target; no dev VM row may record it).

## 26. Fifth window and the full development end to end (2026-10-06)

Fifth window (00:01:24 to 00:06:55 UTC, 5.5 min): `cmuxnp-dev-vmimg-auto5-de18da6` = `sh-d16c97b11a404bf9a1a9849bd0f073bb` from the pushed head de18da6e77c (report logging, resume timer, cmux-cua 0.8.7, dev heartbeat override); bake 184.1 s; smoke PASSED; kept. No push was needed, so the main window token was released unused. The backend lead pointed development at it (Worker cb744d0a). `channels/dev.json` -> auto5; auto3 is the rollback; auto1 is kept until the coordinator's OK.

End to end (`scripts/cmux-next/cloud-dev-e2e.sh`, run 2026-10-06T00:20:50Z on auto5): 17 of 17 PASS.

| Step | ms | Evidence |
| --- | --- | --- |
| sign-in / user.ensure / create / bound | 515 / 778 / 366 / 1,133 | vm_d6e4ca9f27f0fb2c9c5e, host_d634eebd024435c6d64c |
| VM agent evidence | 95 | machine-id per clone, `bind: bound`, keys 0600 |
| first status.report applied | 37 | `report start applied` |
| change report | 10,678 | a report after the activity line (logged `resume held`: see below) |
| heartbeat, 15 s dev override | 40,394 | `heartbeat test override: 15000 ms`, `report heartbeat held` |
| install token / connect_info / link_token | 297 / 118 / 82 | real daemon block |
| pause / start | 320 / 226 | paused, running |
| report after start (resume) | 15,055 | `report resume held` logged 9.8 s after start, before any exec |
| delete | 257 | by this run's id |

Findings:
- Every provider `exec` steps the guest clock (`systemd-resolved: Clock change detected` at each exec; none in 75 s without exec on a debug clone, `cmuxnp-dev-vmimg-auto5-clockdbg`, deleted). Each step fires the OnClockChange resume timer. Production does not exec, so a resume report comes from real resumes; the harness avoids exec while it waits for the heartbeat and the resume report.
- auto5's reporter keeps only the latest reason, so a resume relabeled the change report. Fixed (reasons merge, `change+resume`; reaches VMs with the next bake).
- The resize probe now times the vCPU+memory call and the disk call separately, with UTC start times, to locate the next slow sample (section 18: one 21.2 s outlier in seven samples; latest 274 ms).
- Still open: idle pause (needs the activity sender, section 27) and `cmux link dial` (needs a darwin link build).

## 27. VM activity sender (design, 2026-10-06)

Goal: `cloud.vm.status.report.activity` carries real `last_user_input_at`, `last_agent_action_at` and `active_sessions`, the agent advertises `activity`, and CloudDO's idle pause and the 24 h no_report rule then act on facts. No polling anywhere.

Where the daemon already knows (cmux-tui-core, read 2026-10-06):
- User input: `mux.rs` `note_terminal_input` (Send, SendKey and NoteSizeActivity from attached clients), but v2 `terminal.input.write/keys/mouse` (`resource_router/content.rs` `execute_terminal_effect`), PasteImage and browser input do not pass through it. Raw input is never journaled (spec/session-journal.md), and nothing records wall-clock time.
- Agent action: every agent hook commit goes through `mux.rs` `append_journal_ingress` (producer `cmux_agent`), including tool use, which never reaches `AgentChanged` (`agent_state_for_hook_kind` returns None for `agent.state.changed`).
- Sessions: `ClientRecord.attached` and `kind` (tui, web, mac, frontend) for people; `list_agents` states (Working, Blocked, Idle, Done) for agents.

Design:
1. Daemon owner: a new `mux/activity.rs` (one writer: the Mux) holds `last_user_input_at_ms`, `last_agent_action_at_ms`, `attached_clients` (attached connections whose kind is a person's client) and `live_agents` (agents Working or Blocked). Writers: `note_user_input` from `note_terminal_input` and from `execute_terminal_effect` for input effects; `note_agent_action` from `append_journal_ingress` for non-replayed `cmux_agent` commits; count updates from the attach/detach and agent-state paths.
2. Change events, coalesced: `MuxEvent::ActivityChanged` with leading edge plus a trailing one-shot deadline at most 1 per second (keystrokes do not flood; the launch_snapshot settle pattern), never a tick.
3. Wire: a dedicated `subscribe-activity` command in `server/activity.rs` (one delegating arm in server.rs; it has 16 lines of god-file headroom): first line `{id, ok, data: {activity}}`, then `{"event":"activity-changed","activity":{...}}` lines. Capability `vm-activity-v1` in `server/capabilities.rs`. Spec inventory, commands.md, events.md, sdk-schema and the TypeScript bindings get the new names (check-spec-inventory.py).
4. Agent: when identify advertises `vm-activity-v1`, it keeps one subscription open (reconnect with Backoff only after a failure, e.g. a daemon re-key restart) and maps each event to `reporter.update({active_sessions: attached_clients + live_agents, last_user_input_at, last_agent_action_at})`. It advertises `activity` only while it has that subscription and the daemon advertises the capability. Reports then follow section 17 (1 per 10 s, latest wins).
5. Privacy: times and counts only; no content, no surface ids leave the VM.

Tests (red first): Rust unit tests for the activity reducer (input from an attached client sets the time; an unattached one-shot send does not; a replayed journal commit does not; counts follow attach/detach and agent states; coalescing emits leading + trailing, never more than 1 per second with a fake clock), a server wire test for `subscribe-activity`, and agent tests against a fake daemon socket (mapping, capability only with the daemon capability, reconnect after a drop). Gate: Testbox `cargo test -p cmux-tui-core activity` plus the focused hosted run. Window: cmux-tui window (server.rs arm, spec JSON and bindings change: not WINDOW-LITE).

## 28. Activity sender landed; auto6 pin (2026-10-06)

The daemon side landed as d4c9d5e58082 on feat-cmux-next (window f2801b6b9ddf); the focused cmux-tui.yml on it (run 37424077191) passed. The image pin is cmux-tui 4b534636000bf6075ecaef6995e29cb93a05e7ae (artifacts run 37424457494, sha256 and size checked against its manifest), not d4c9d5e58082: that commit's cmux-tui-artifacts run 37424051769 was cancelled and published nothing (files.cmux.com 404). d4c9d5e58082 is an ancestor of 4b534636000 (git merge-base --is-ancestor). Pins come from CI artifacts by commit and sha256; no GitHub release is involved.

Evidence gates for this pin (coordinator conditions): the bake runs `vm-agent.ts --probe-activity` after recording daemon.json and fails unless the daemon advertises vm-activity-v1 and the agent's own ActivityWatcher connects and receives a snapshot; the smoke repeats it as `vm-activity-stream` on a clone.

safe-push WINDOW-LITE: a Cargo.toml needs a window only for a cmux-tui workspace member or the workspace root (`.cmux-scratch/nx-worker/safe-push-members.py` reads `[workspace] members/exclude` at HEAD, per-component globs; fail closed). Tests: `safe-push-test.sh` cases windowlite-manifest-{nonmember,excluded,member,glob-member}. The equality with `cargo metadata --no-deps` is checked on a Testbox (`safe-push-members.py --check-cargo-metadata cmux-tui`).
