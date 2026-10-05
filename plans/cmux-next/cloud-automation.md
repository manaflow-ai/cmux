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
