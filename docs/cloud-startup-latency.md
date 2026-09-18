# Cloud machine startup latency: measured baseline, lower bound, and the path to it

Issue: https://github.com/manaflow-ai/cmux/issues/12905 (complements #12672 create
failures, #12537 terminal startup, #12624 auth waits, #12625 refresh pressure,
#11008 connection deadlines). Investigation date: 2026-09-17/18. Branch
`12905-cloud-startup-latency`. Raw artifacts: `docs/cloud-startup-latency/`.
Reproducible tooling: `web/scripts/cloud-vm/bench-*.{mjs,ts}` (section 10).

## 1. Answer

**Measured today (production, Nightly, unnamed New Machine, warm WireGuard
hub):** about **4.2–5.5 s** from the click to a usable shell prompt at the
median, built from measured pieces: the create request (client p50 1.07 s,
p90 2.97 s over 14 days), the attach-endpoint request on the fresh machine
(1.2–1.5 s in this session's runs), link and terminal creation (~0.4 s), and
the guest shell's own startup (1.1 s to the first prompt). Tails go far
beyond that: the attach route's server-side p95 was 14–17 s between
2026-09-10 and 09-16 (daemon heal path), a *named* create pays a serialized
rename exec whose p90 is 13.9 s, Vercel cold starts add ~2.4 s to the first
call of a route, and the auth refresh stall in #12624 can hold a create for
minutes. The "~10 seconds sometimes" report is consistent with any one of
those tails landing on top of the 4–5 s median.

**Provider floor (measured with the Freestyle SDK directly, n=5):**
allocation returns in **0.44 s** median and the daemon bound to this machine
is listening **1.21 s** after the create call started. Pause/resume is far cheaper:
start returns in 0.09 s and the daemon is listening 0.14 s after the resume
request (a figure that includes the start call). Exec round
trip is 25 ms. Three concurrent creates cost 0.45 s each (no meaningful
contention).

**Lower bound with every feature intact (this architecture, this provider):**
about **1.5 s** to a usable prompt for a fresh machine (0.15 s control plane,
0.44 s allocation, ~0.3 s daemon start once the supervisor is event-driven,
~0.3 s link + snapshot + terminal, ~0.3 s shell with ble.sh kept but deferred), and
about **0.3 s + shell** for resume/reconnect (0.14 s from the resume request
to a listening daemon, 0.14 s link). This is a floor derived from
measured stage costs, not a guarantee: allocation and daemon boot are
provider/image properties measured at one vantage point on one day.

**Engineering target:** **2.0–2.5 s p50 and ≤ 4 s p95** for a fresh unnamed
create to prompt, **≤ 1.5 s** for reconnect/resume to prompt, with no feature
removed. The gap between today and the target is almost entirely serialized,
duplicated guest work and control-plane round trips (section 6), not
provider time.

**Recommended design (ranked in section 8):** (1) collapse the attach path
to one guest exec and stop re-installing baked components on every attach;
(2) bake the guest shim and resource reporter and accept `displayName` at
create so create does one provider call and no rename; (3) let the client
dial the daemon straight from the create response while the hub warms in
parallel, with the attach-endpoint kept only as the repair path; (4) make
the guest supervisor start the daemon on resume instead of on a 1 s poll;
(5) trim the guest shell's startup; (6) remove the double heal and 1 s poll
from resume. Warm inventory (a pre-created spare machine per user) was
evaluated and is *not* recommended now: after (1)–(6) it would buy ~0.8 s for
per-user disk cost, image-staleness handling and a new reconciliation
surface.

## 2. Scope and evidence sources

Measurements used, with their sample counts:

| Source | What it measures | Window / n |
| --- | --- | --- |
| PostHog `cloud_vm_request` (server, schema 2) | every `/api/vm*` request the server handled, `duration_ms` per operation, by client channel/build | 14 days to 2026-09-18, 240k events |
| PostHog `cmux_cloud_vm_request` (Mac client, schema 1) | the same requests as the client saw them, joined to the server rows by `client_trace_id` | 14 days, 415k events |
| `bench-vm-startup.mjs` | create → attach → warm attach → exec → pause → resume-attach → destroy against a deployed backend, with the create route's `Server-Timing` stages | staging n=5 sequential + n=3 concurrent + n=3 with edge probe; production n=3 sequential |
| `bench-freestyle-floor.ts` | provider-only floor with the SDK: allocation, daemon process/listen, announce, exec/fs RTT, guest shell startup, pause/start/delete | md n=5 + burst 3; sm n=3 |
| `bench-private-link.ts` | the app's transport path headlessly: production driver create, attach bundle, WireGuard hub, `cmux-tui remote connect --carrier`, snapshot, `bash -l`, prompt visible, reconnect | md n=3, client `e90a212` (Nightly bundle), with production's prompt identity and persisted addresses |
| PR #12739 native measurements | Mac-side Cmd-D/Cmd-T phases on a warm link (Debug build) | 10+10 trials |
| Source trace | the dependency graph in section 3 | HEAD `e4176d8d53` |

Not measured, stated plainly: the Mac UI's click-to-first-frame for a New
Machine (a GUI lane was not available: macfleet is retired, the cloud-mac
skill depends on it, and no controller job system was found in the HQ
checkout), and Axiom per-stage spans (the production read token is rejected
by the Axiom API as "token not supported"). The end-to-end figure in
section 1 is therefore a sum of measured stages plus PR #12739's native
numbers, not a stopwatch on the app.

All experiments used scoped resources: throwaway Stack users on staging and
production, benchmark-owned VPCs, tunnels and machines, all deleted at the
end of each run. No existing user machine was read or modified.

## 3. Dependency graph: New Machine → usable terminal → full features

Click "Create" in the sheet (`NewMachineModel` → `MachineCreateCoordinator`
→ `CloudVMActionLauncher`) spawns the bundled CLI `cmux vm new --desktop
--size N --focus false`. Everything below is **serial** unless marked.

| # | Stage | Where | Measured cost (p50) | Avoidable? |
| --- | --- | --- | --- | --- |
| 1 | CLI process start, socket connect, `vm.create` admission | Mac | ~50–100 ms (not measured separately) | mostly no |
| 2 | `VMClient.create` waits for `AuthCoordinator.currentTokens()` | Mac | 0 normally; minutes in the #12624 stall | yes (owned by #12624) |
| 3 | `POST /api/vm`: auth 0.3 ms, entitlements 0.2 ms, begin_create (DB tx, advisory lock, slug) 30–48 ms, resolve_network 35–78 ms (p90 200–500 ms), model_plane_provision 3–9 ms, **provider_create 1.30–1.31 s**, mark_running 5–10 ms, usage_events 7–17 ms; server total 1.41–1.42 s; client-observed 1.47–1.51 s | Vercel | 1.4–1.5 s (Nightly client p50 1.07 s, p90 2.97 s) | provider_create is ~0.4 s allocation + ~0.85 s guest work (row 4) |
| 4 | Inside provider_create: `vms.create` (0.44 s), address validation, **`installGuestCli`** (fs write 35 ms + exec chmod/mv + prompt install python; since #12741 the same exec also installs the guest browser openers), **`ensureResourceReporter`** (exec: write unit, `systemctl daemon-reload`, `restart`, `enable --now`) | Vercel → guest | ~0.85 s | **yes**: bake shim, openers and reporter; prompt already re-applied at attach |
| 5 | `vm.rename` (only when a name was typed): DB update + guest prompt-install exec, 30 s socket timeout, best-effort but synchronous in the CLI | Vercel → guest | p50 281 ms, **p90 13.9 s** (n=24) | **yes**: accept `displayName` at create |
| 6 | `vm.cmux_remote_info` → `POST /api/vm/{id}/attach-endpoint`: auth, `requireAccessibleUserVm`, `getStatus` provider probe, **announce exec** (~100 ms), **attach bundle exec** with the settle loop (up to 3 s, 100 ms ticks, two metadata curls per tick), **shim + browser-opener check exec** (sha256 of the shim plus `guestBrowserReadyCommand`, added by #12741 on 2026-09-18, after this session's runs), **hooks-ready exec** (python), **reporter-install exec** (systemctl), lease + usage + metadata DB writes | Vercel → guest | fresh machine 1.2–1.5 s (this session, before #12741); existing machine Nightly p50 0.75 s; server p50 1.12 s, p95 14.9 s (14 d) | **yes**: one exec; skip baked components; readiness by dialing |
| 7 | Hub pin (`wg hub` spawn + socket ready) and route probe (SOCKS connect race across families) | Mac | hub cold 0.24 s, tunnel enroll 0.12–0.30 s (first time), probe ~1 RTT | yes: overlap with row 3 |
| 8 | `workspace.create` (placeholder pane), `workspace.cloud_vm_bind` | Mac | ~10–20 ms | no |
| 9 | `surface.catalog refresh:true` for the machine: link `remote connect --carrier` (**0.14 s**, reconnect 0.13 s), `session current snapshot` (57 ms), fleet list (0.2–1.2 s cold) | Mac → guest | 0.3–0.5 s | partly: the list is not needed to open the terminal |
| 10 | `surface.new_terminal` → `workspace <ws> run -- bash -l` (132 ms) → manual-mirror attach + first frame (90–330 ms, PR #12739) | Mac → guest | 0.2–0.45 s | little |
| 11 | Guest shell to first prompt: `bash -l` profile chain (agent-config, terminfo, desktop env) 0.51 s; interactive shell with ble.sh 1.10 s under a pty; prompt visible 1.06 s after `run` over the real link | guest | **1.1 s** | partly: ble.sh load and profile chain |
| 12 | Desktop (Displays row): `open-port` API (p50 633 ms, 14 d) runs `systemctl start cmux-desktop` (no-op, the desktop is live in the memory snapshot) then the browser proxy + noVNC load | Vercel → guest → Mac | ~1–2 s, in parallel with 10–11 if opened | partly: skip the heal exec when the daemon reports the desktop up |
| 13 | Model plane (coderouter edge injection) | provider edge | already answering 200 at the first probe, 3–5 s after create, in 3/3 trials | n/a |

Rows 3–6 are the control plane; rows 7–11 are the Mac; rows 11–13 are
the guest. The provider's own contribution is inside row 4 (0.44 s) plus
the daemon boot that overlaps rows 5–6 (listening at +1.21 s from the
create call).

## 4. Measured baselines

### 4.1 Production telemetry (PostHog, 14 days to 2026-09-18)

Server-side, successful requests (`docs/cloud-startup-latency/posthog-baseline-14d.txt`):

| Operation | n | p50 | p90 | p95 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| create | 221 | 935 ms | 1661 | 2025 | 5600 |
| create (nightly) | 98 | 982 ms | 1943 | 2652 | 5600 |
| open_attach (attach-endpoint) | 81 299 | 1122 ms | 3389 | 14 921 | 65 911 |
| enroll_tunnel | 696 | 174 ms | 428 | 500 | 6307 |
| exec | 8838 | 75 ms | 981 | 1214 | 182 291 |
| open_port | 103 | 633 ms | 881 | 946 | 10 481 |
| rename | 24 | 281 ms | 13 880 | 13 949 | 14 072 |
| destroy | 204 | 478 ms | 25 451 | 43 806 | 56 971 |
| restore / fork / snapshot | 4 / 1 / 5 | 1.1 s / 10.7 s / 3.9 s | 28 s / – / 32 s | | |

Client-side (Nightly), joined to the server rows by trace id:

| Request | n ok | client p50 | client p90 | client p95 | client − server overhead p50 / p90 / p95 | failures |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| POST /api/vm | 98 | 1074 ms | 2970 | 3300 | 73 / 793 / 1540 ms | 17 (p50 321 ms; 402/409 plan and idempotency) |
| POST attach-endpoint | 6962 | 748 ms | 1079 | 1343 | 69 / 173 / 215 ms | 1327 (1314 × 502 p50 4.5 s p95 15 s; 4 × 504 at 300 s) |
| POST /api/vm/tunnel | 665 | 304 ms | 637 | 836 | | 1250 (1244 × 503, p50 193 ms) |
| POST exec | 7050 | 124 ms | 2457 | 2657 | | 13 |

Trend that matters (attach-endpoint success, per day, `posthog-attach-detail.txt`):
p50 was 548–650 ms on 09-04…09-08 and 1138–1227 ms from 09-13 on; p95 was
0.8–0.95 s and became 14–17 s from 09-10 to 09-16 (6.3 s on 09-17). The
private-network announcement exec (network.ts, measured 2026-09-10), the
attach-time hooks and reporter installs and the settle loop entered the
attach path in that window; the per-day series is consistent with them
adding ~0.5 s at the median and the heal path owning the p95.

Also visible: 9335 `approve_cmux_remote_enrollment` 502s with p50 33.9 s
(older clients still on the invitation flow) and 1244 tunnel-enroll 503s
(`vm_tunnel_enrollment_unavailable`/kill switch). Neither is on the current
trusted-carrier path but both are real user-visible waits.

### 4.2 Control-plane benchmark (`bench-vm-startup.mjs`, this session)

Same image ladder (`freestyle-cmux-cloud-latency-12739-r4-md`, daemon
`68df8eec`), one vantage point, throwaway Pro user. Values are p50 with the
range in parentheses.

| Stage | Staging n=5 seq | Production n=3 seq | Staging n=3 concurrent |
| --- | --- | --- | --- |
| create (client) | 1513 ms (1410–2986) | 1469 ms (1460–2371) | 1759 ms (max 3220) |
| server total / provider_create | 1410 / 1296 ms | 1422 / 1314 ms | 1714 / 1390 ms |
| resolve_network | 34 ms (28–199) | 78 ms (47–222) | 296 ms (max 451) |
| begin_create | 30 ms (25–93) | 48 ms (42–71) | 42 ms |
| attach (fresh machine, first call) | 849 ms (780–1271) | 1491 ms (1211–4349) | 1100 ms |
| create → attach OK | 2340 ms (2259–4258) | 3862 ms (2681–5809) | 2876 ms |
| warm attach (second call) | 906 ms (884–992) | 1458 ms (1179–1696) | 826 ms |
| exec `true` | 373 ms (365–2228) | 2455 ms (456–2777) | – |
| pause | 297 ms | 761 ms | – |
| attach after pause (resume path) | 1735 ms (1692–1909) | 2401 ms (2133–2585) | – |
| destroy | 244 ms | 841 ms (760–14 198) | 204 ms |
| model-plane edge answering (staging, n=3) | first probe 200 in 3/3 (0.40 s exec; one 3.0 s cold start) | | |

The 2.2–2.8 s exec samples and the 3.2 s create in the concurrent batch are
the first invocation of a Vercel route function: cold starts, not guest
time. Every attach succeeded on the first call (no 502/retry in 17 trials),
so the settle loop covered the create→attach race in this session.

### 4.3 Provider floor (`bench-freestyle-floor.ts`, SDK only)

Readiness here is the image's own health predicate: the daemon process runs,
something listens on 1337, and the daemon is the one bound to this machine's
instance id (a clone briefly runs the source machine's daemon until the
supervisor re-keys it, and that stale listener does not count). Each
milestone is late by up to one 250 ms probe interval plus one ~25 ms exec.
An earlier run that checked only the listener read 1.06 s; its allocation
and first exec were also faster that day, so the re-key's own cost is at
most ~0.15 s of the difference.

| Stage (md, n=5; sm, n=3) | md p50 (range) | sm p50 |
| --- | --- | --- |
| `vms.create` returns, state `running` | 441 ms (415–524) | 479 ms |
| first successful guest exec | 582 ms | 668 ms |
| daemon process running (supervisor tick) | 913 ms (866–1051) | 1056 ms |
| daemon listening on 1337, bound to this machine | **1214 ms** (1167–1352) | 1378 ms |
| strict announce exec | 133 ms | 138 ms |
| exec RTT / `data()` / 20 KB fs write | 25 / 17 / 34 ms | 25 ms |
| `bash -lc true` as work user (guest clock) | 505 ms (361–580) | 437 ms |
| interactive `bash -il` under a pty with ble.sh (guest clock) | 1101 ms (1087–1298) | 1029 ms |
| pause / start | 177 (p90 218) / 92 ms | 200 / 98 ms |
| daemon listening after the resume request (includes the start call) | 141 ms | 156 ms |
| delete | 84 ms | 105 ms |
| burst of 3 concurrent creates: allocation / listening | 449 / 1191 ms | – |

So the machine exists and executes commands ~0.6 s after the request, the
daemon that is valid for it is reachable ~0.6 s later, and a memory-preserving
resume is ~0.14 s end to end (`resumeDaemonListenMs` is measured from before
`start()`, so the 141 ms already contains the 92 ms start call; the first
probe after `start()` returns already sees the listener). The supervisor's
1 s poll (`cmux-devbox-boot`) is visible as the 0.33 s between first-exec and
daemon-process; daemon start to listen is ~0.30 s.

### 4.4 Transport benchmark (`bench-private-link.ts`, md, n=3)

Measured with the inputs the production workflow passes: the machine's
prompt identity at create and at attach (the guest installs its prompt each
time) and the addresses persisted at create fed back into the attach, which
then skips the provider read.

| Stage | p50 (range) |
| --- | --- |
| VPC create / tunnel create / hub ready (once per run) | 1179 / 99 / 156 ms |
| `FreestyleProvider.create` (production driver: alloc + validate + shim + prompt + reporter) | 1140 ms (1124–1248) |
| `openCmuxRemote` (announce + prompt + bundle + hooks + reporter) | 694 ms (626–715) |
| create → attach bundle OK | 1839 ms |
| `remote connect --carrier` via hub to connection-snapshot | 139 ms (123–219) |
| session snapshot | 57 ms |
| `workspace run -- bash -l` | 132 ms |
| run → prompt (`λ`) visible | **1061 ms** (975–1106) |
| create → prompt visible | **3127 ms** (3076–3132) |
| reconnect (second link) | 128 ms |

This is the whole path minus the Mac UI and minus the Vercel/DB/auth layer:
3.1 s, of which 0.44 s is allocation and 1.1 s is the guest shell. An
earlier run without the prompt identity measured the attach bundle at 609 ms
and create → prompt at 3084 ms, so the prompt install costs about 85 ms
inside the one bundle exec.

### 4.5 Scenario matrix

| Scenario | Today (p50, measured pieces) | Floor | Target |
| --- | --- | --- | --- |
| Fresh cold create, unnamed, hub warm | ~4.2–5.5 s to prompt | ~1.5 s | 2.0–2.5 s |
| Fresh create, named | + 0.3 s p50, + 14 s p90 (rename exec) | + 0 | + 0 |
| Fresh create, first machine on this Mac | + tunnel enroll 0.3 s + hub 0.24 s + NE approval if a browser needs it | + 0.3 s (overlappable) | overlapped with create |
| Resume a paused machine from the sidebar | attach-resume 1.7–2.4 s + link 0.14 + terminal 0.2 + shell 1.1 ≈ 3.2–3.9 s | ~0.3 s + shell | ≤ 1.5 s |
| Reconnect to a running machine (app already linked) | Cmd-D/Cmd-T open 0.25–0.66 s + shell (PR #12739) | 0.15 s + shell | ≤ 0.5 s + shell |
| Reconnect after app restart | attach-endpoint 0.75 s (route cache empty) + link 0.14 + snapshot 0.06 + terminal | link only (route persisted) | ≤ 0.5 s + shell |
| 3 concurrent creates | create 1.76 s, attach 1.10 s each | allocation 0.45 s each | as sequential |
| Full features (desktop visible, agents' credentials) | desktop +1–2 s in parallel; edge already up | desktop ~0.3 s | desktop ≤ 0.5 s after link |

## 5. Lower-bound budget (explicit assumptions)

Fresh cold create to a usable prompt, everything on the critical path and
nothing that can be overlapped:

| Component | Floor | Basis | Confidence |
| --- | --- | --- | --- |
| Control plane admission (auth verify, one DB transaction, response) | 0.10–0.15 s | Server-Timing: auth 0.3 ms, begin_create 30–48 ms, mark_running 5–10 ms, plus one client RTT ~70 ms | high |
| Provider allocation | 0.44 s | 8 SDK creates: 415–524 ms | high for this vantage/day; provider-owned |
| Daemon ready | 0.30 s | process→listen 0.30 s measured, identity-verified; assumes the supervisor starts it immediately on resume (today 1 s poll) | medium |
| Reachability + link | 0.12–0.15 s | measured link 123–219 ms (p50 139); the boot-time announce runs before the daemon listens | high |
| Snapshot + terminal create | 0.19 s | 57 + 132 ms measured; one multiplexed request could shave ~50 ms | high |
| Shell to prompt | 0.30–0.50 s | `bash -lc` 0.36–0.58 s today; ble.sh adds ~0.6 s; assumes a trimmed profile chain and ble.sh loaded after the first prompt | medium |
| **Sum** | **~1.5–1.7 s** | | |

Unavoidable by construction: one RTT to the control plane, provider
allocation, daemon start, one RTT to dial, shell startup. Everything else
in today's 4–5.5 s is avoidable serialized work: ~0.85 s of create-time
guest installs, 0.6–1.5 s of attach-time execs and DB writes, 0.3 s of
supervisor polling, 0.2–0.5 s of hub/probe/list work that could overlap
the create, ~0.6–0.8 s of shell startup that could be deferred, and the
tails (rename, heal, cold starts, auth stall).

The engineering target (2.0–2.5 s) keeps a margin over the floor for the
things not worth removing: the attach-time lease ledger write, the fleet
list refresh, ble.sh with its cache, and the first-frame pipeline.

## 6. Where the time goes: avoidable work, with evidence

1. **Create does three guest round trips after allocation** (`installGuestCli`: fs write + exec; `ensureResourceReporter`: exec running `systemctl daemon-reload/restart/enable`). provider_create is 1.30 s from Vercel against a 0.44 s allocation; the transport bench shows the same 1.06 s vs 0.41 s from a closer vantage. The shim and the reporter unit are static per image epoch; the bake already installs the daemon, its pin and the agent hooks the same way. The prompt identity is re-applied by the attach bundle anyway (`promptSetup` in `openCmuxRemote`).
2. **Attach runs five to six guest execs serially** (announce; bundle with a settle loop that runs two metadata-service curls per 100 ms tick; since #12741 a shim-sha256 + browser-opener readiness check; hooks-ready check with a python JSON parse; reporter install with systemctl) plus a `getStatus` provider probe and three DB writes. Measured 0.61 s from the Mac and 0.85–1.5 s through Vercel before #12741 landed; per-day production p50 doubled when the first of these entered the path on 2026-09-10. On current images the hooks check is always a no-op (the bake proves hooks installed), the shim/opener check is a no-op after the first attach, and the reporter compare/enable is a no-op after the first attach. Each addition is individually small (one exec is ~20 ms of RTT plus its work), which is exactly why the count keeps growing; the fix is structural (one exec, gated by the image epoch), not per-feature.
3. **Named creates serialize a rename exec** (p90 13.9 s, n=24) before opening the shell. The server already installs the prompt name inside create when `promptIdentity` is passed; the create route just does not accept a display name.
4. **The daemon waits for a 1 s supervisor tick**: first exec succeeds at 0.58 s, the daemon process appears at 0.91 s, listens (bound to the machine) at 1.21 s. A systemd path/oneshot triggered at resume, or an immediate check at supervisor start, removes ~0.3 s.
5. **Resume heals twice and polls at 1 s**: `resume()` calls `ensureCmuxTuiRunning` (shim install, settle exec, hooks), then `openCmuxRemote` runs announce + bundle + hooks + reporter again; `waitForRunningStatus` sleeps 1 s between probes. Provider floor is 0.09 s start + 0.14 s daemon; measured resume-attach is 1.7–2.4 s.
6. **The client learns the route only from the attach-endpoint**, so the hub pin and route probe start after that request and the link after those. The create response already carries the private addresses; the daemon's Noise handshake is the real readiness proof.
7. **Guest shell startup is 1.1 s to the first prompt**: `bash -l` profile chain 0.5 s (agent-config generators, terminfo, desktop env, ble.sh cache seeding), ble.sh source ~0.6 s. Every new terminal pays it, not only startup.
8. **Vercel cold starts**: the first call of a route function costs ~2–3 s (exec 2.4 s vs 0.37 s warm, staging list 1.2 s cold). Production exec p90 in telemetry is 2.46 s for a 75 ms server operation.
9. **Polling and timeouts around the path**: fleet poll 45 s (the "Creating…" row is replaced only after a refresh; the coordinator does trigger one on the marker), stats 20 s per machine (#12625), CLI `vm.cmux_remote_info` 16 min socket timeout, `VMClient.createTimeoutSeconds` 16 min, link connect 60 s, hub socket wait 45 s (#11008 owns command deadlines).
10. **Auth wait before the request** (#12624): client−server overhead is 73 ms at p50 but 0.8–1.5 s at p90/p95 for create, and the issue documents 10-minute spans.

## 7. Architectures evaluated

| Option | Effect on startup | Cost / capacity | Tail latency | Isolation & security | Image freshness / state | Failure recovery | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Trim serialized work** (bake shim/reporter, one attach exec, displayName at create, no double heal) | −1.5 to −2.5 s p50; p95 heal path only on real failures | none | removes the 13.9 s rename and most 14–17 s attach p95 | unchanged (same private network, Noise, lease ledger) | shim/reporter ride the image epoch like the daemon pin already does | fewer execs, fewer transient netlink/exec timeouts (the #12687 failure class) | **do first** |
| **Event-driven readiness** (client dials from the create response; daemon-ready proven by the handshake; attach-endpoint becomes the repair call; supervisor starts daemon on resume) | −0.75 to −1.5 s (attach RTT) −0.3 s (tick) | none | dial retries bounded by the existing reconnect policy (100 ms → 5 s, 15 s attempt) | lease must be recorded at create for the creator's device or after the first dial; admission is unchanged (VPC membership) | none | a machine whose daemon never comes up shows "connecting" until the repair call runs (bounded, e.g. after 3 failed attempts) | **do second**, needs the lease-ledger decision |
| **Parallel initialization** (hub/tunnel/route probe while create is in flight; desktop open in parallel with the terminal; fleet list off the open path) | −0.2 to −0.5 s | none | none | none | none | none | do with the above |
| **Prebuilt/versioned images** | already the design (memory snapshot with daemon parked, desktop live) | rebake per epoch | – | – | promotion invariants already enforced | – | keep; add daemon-start-on-resume |
| **Snapshot/resume as the default open** (keep machines paused, resume on open) | resume floor 0.14 s vs create 1.21 s | paused = disk only | pause p90 1.06 s observed | none | user data persists anyway | none | already available (`pause`); make resume cheap (item 6) |
| **Warm inventory** (one spare paused machine per active user/team) | −0.8 s on fresh create after the above | one extra 16–32 GB disk per user; naming/limit/billing exceptions; recreate spares on every image promotion | none | spare must be created in the user's VPC with the user's edge rule: fine | staleness: spares older than the manifest must be discarded | new reconciler, new orphan class | **not now**; revisit if allocation regresses above ~1 s |
| **Connection reuse** | app already keeps one link per machine and one hub; persisting the route (already) lets a restart skip attach | none | – | – | – | – | keep; extend to pre-dial on fleet discovery |
| **Faster shell** (deferred ble.sh, trimmed profile) | −0.5 to −0.8 s on every terminal | none | – | – | image change | – | do, with parity tests for ghost text and prompt |

## 8. Ranked implementation plan

Each item lists the expected saving on the fresh-create path (p50), the
proof required before claiming it, and ownership overlap.

1. **Attach: one exec, no re-installs, readiness by dial** (web driver). Merge announce + settle + probe + devices + trusted-listener into one script; skip the shim/opener, hooks and reporter checks when `/etc/cmux/image-stamp` epoch ≥ the epoch that bakes them; skip the `getStatus` probe for rows created in the last minute; move lease/usage/metadata writes to `after()` where the response does not depend on them. Expected: server p50 1.12 s → ~0.35–0.45 s, p95 15 s → ≤ 2 s. Proof: `bench-vm-startup.mjs` before/after (n ≥ 10 staging, n ≥ 5 production) plus PostHog open_attach p50/p95 by build; provider tests asserting the exec count. Overlap: #12672 (create/attach outcome) — coordinate on the driver; #12537 owns the UI.
2. **Create: allocation only** (image + web). Bake `/usr/local/bin/cmux` shim, the guest browser openers (`guestBrowser.ts`) and the `cmux-resource-stats` unit into the devbox (add them to `devboxSourceDigest`), drop `installGuestCli` and `ensureResourceReporter` from create (keep the heal-time install for pre-epoch images), accept `displayName` in `POST /api/vm` and set it in the create transaction, make the CLI's rename fire-and-forget. Expected: provider_create 1.30 s → ~0.5 s; named-create tail −14 s. Proof: Server-Timing provider_create before/after; regression test that create issues zero guest execs on a current-epoch image. Overlap: #12672.
3. **Client: dial from the create response; hub in parallel** (Mac). `vm new` receives the private addresses in the create response; pin the hub and probe the route while the create is in flight; dial `--carrier` immediately and call attach-endpoint only when the dial fails N times (repair). Persist the route for later opens (already done). Expected −0.75 to −1.5 s. Proof: `cli.vm.timing` stages on a tagged build; native phases from `CloudOperationRecorder` (`open.tunnel/route/connect`). Overlap: #12537 (readiness presentation), #11008 (deadlines).
4. **Guest supervisor: start the daemon on resume** (image). Replace the 1 s tick for the clone check with an immediate check at supervisor start plus a metadata/instance-id watch, keep the 30 s announce loop. Expected −0.3 s. Proof: `bench-freestyle-floor.ts` daemonListenMs p50 1.21 s → ≤ 0.9 s on the promoted image.
5. **Guest shell: prompt in ≤ 0.5 s** (image). Profile `/etc/profile.d` + bashrc chain; defer ble.sh sourcing until after the first prompt (or precompile), keep ghost text, prompt name and agent configs. Expected −0.5 to −0.8 s per terminal. Proof: floor bench loginShell/interactivePty before/after; `bench-private-link.ts` runToPromptMs; parity checks for ghost text and prompt name.
6. **Resume: single heal, fast poll** (web). Skip `ensureCmuxTuiRunning` on resume when the pinned daemon is present; poll `getStatus` at 200 ms; let `openCmuxRemote` do the one exec from item 1. Expected resume-attach 1.7–2.4 s → ~0.5 s. Proof: bench resumeAttachMs.
7. **Control-plane tails** (ops + web). Measure and remove cold starts for the cloud routes (Fluid compute/keep-warm; verify with the exec p90 in PostHog), batch DB writes, keep `resolve_network` off the create path for returning users (row already holds the network id). Expected p90 −2 s.
8. **Observability**: emit `cmux.vm.timing.*` stages and `Server-Timing` from the attach route as create does; add the three benchmarks to a scheduled staging job with thresholds (create ≤ 1.0 s server, attach ≤ 0.5 s, resume-attach ≤ 0.7 s) so regressions like the 09-10 one are caught within a day.

Not in this plan: warm inventory (section 7), provider changes (allocation
and boot are already at 0.4 s and 0.3 s), and the auth-refresh stall (#12624
owns it; it is the largest single tail and must land regardless).

## 9. Feature-parity matrix

| Feature | Where it lives | Items 1–8 keep it by |
| --- | --- | --- |
| Persistent home / data | machine disk, memory snapshot | untouched; no volume changes |
| Terminal sessions and scrollback | cmux-tui daemon in the guest, journaled state | daemon and protocol unchanged; only when it starts changes |
| Desktop / noVNC | `cmux-desktop` unit live in the snapshot; open-port over the tunnel | unchanged; optional: skip the heal exec when the daemon snapshot reports the display |
| Tools and agents (Claude Code, Codex, OpenCode, pi, hooks) | baked; hooks installed at bake | the attach-time hooks check is skipped only when the image stamp proves the bake; older epochs keep the heal |
| Guest `cmux` shim, browser openers, resource reporter | installed at create/attach today | baked into the image; heal keeps installing on pre-epoch images |
| Auth and authorization | Stack session, team ownership, private network membership, Noise handshake, lease ledger | unchanged trust boundary; lease recorded at create or after the first dial instead of before |
| Networking / ports / publications | VPC + WireGuard hub, `openPort`, publications | unchanged; hub started earlier, not differently |
| Snapshots / forks / restore | provider snapshots via workflows | unchanged; restore/fork inherit the cheaper attach |
| Reconnect / recovery | link reconnect policy, events recovery, heal on attach | attach-endpoint stays as the explicit repair path |
| Quotas and billing | Postgres limits, usage events, credits | unchanged; usage writes may move after the response but still happen once |
| Entry points (sheet, `cmux vm new/shell/open`, sidebar, agents over the socket) | shared `vmOpenShell` / catalog path | one shared path changes; all entry points benefit |

## 10. Reproduce

```bash
cd web && bun install --frozen-lockfile
# Provider floor (needs FREESTYLE_API_KEY from ~/.secrets/cmux.env; creates and deletes its own VPC and machines)
bun scripts/cloud-vm/bench-freestyle-floor.ts --trials 5 --burst 3 --out /tmp/floor.json
# Transport path with the Nightly-bundled client (or --client <path to cmux-tui>)
bun scripts/cloud-vm/bench-private-link.ts --trials 3 --out /tmp/link.json
# Control plane (throwaway Pro user; Vercel env pulled like the smoke script)
bun scripts/cloud-vm/bench-vm-startup.mjs staging --trials 5 --out /tmp/api.json
bun scripts/cloud-vm/bench-vm-startup.mjs staging --trials 3 --concurrency 3 --skip-pause --skip-exec
bun scripts/cloud-vm/bench-vm-startup.mjs staging --trials 3 --edge-check --skip-pause
bun scripts/cloud-vm/bench-vm-startup.mjs production --trials 3
bun test tests/cloud-vm-bench-stats.test.ts
```

PostHog queries are in `docs/cloud-startup-latency/posthog-*.txt` headers
(HogQL over `cloud_vm_request` and `cmux_cloud_vm_request`, project 244066).

## 11. Incidental findings from the benchmark runs

- **A create request can leave a second, untracked machine running.** In the
  staging run with the edge probe (2026-09-18, three creates), two requests
  (traces `d492bc1c446e396f3895bf5063ed2a3e` at 00:57:50Z and
  `e3a2a242aac5a594ffb0236d220354ee` at 00:58:01Z) each returned one machine
  id, which the benchmark later destroyed, while a second machine from the
  same snapshot appeared on the same owner VPC 0.7 s and 0.4 s after each
  request started and was still running 30 minutes later, unknown to the
  control plane. The route's `provider_create` stage shows one provider call
  per request (2174 ms and 1507 ms), `providerGateway.ts` has no retry, and
  the SDK re-issues only idempotent GETs, so the client side does not explain
  it; the other 21 creates of the session did not do this. Both orphans were
  deleted by hand after verifying they belonged to the throwaway user's VPC.
  This is the created-but-lost class #12672 asks to reconcile: a periodic
  provider-versus-`cloud_vms` reconciliation per owner network would catch
  it, and the provider-side request logs for those two traces should say
  whether the platform allocated twice.
- **Throwaway-user scripts leak owner networks.** `smoke-vm-api.mjs` and
  `stress-vm-api.mjs` delete their Stack user with the server key, which
  leaves the user's provider VPC (`cmux-net-<hash>`, created by the first
  create) and its `cloud_vm_networks` row behind on every run. The eight
  networks this session's early runs left were removed by hand after
  verifying they had no machines or tunnels. `bench-vm-startup.mjs` now
  deletes the account through `DELETE /api/account`; when that route does
  not complete it removes the owner network at the provider by the
  application's slug, keeps the Stack identity so the route's resumable
  deletion can be retried, and exits 1. The smoke and stress scripts should
  adopt the same cleanup.
- **Account deletion fails on staging at its last step.** `DELETE /api/account`
  answered `500 account_delete_retryable` three times in a row for a
  throwaway user after it had already destroyed the cmux-owned data (the
  Stack deletion step); the route's owner should check the staging Stack
  configuration. Until it is fixed, every staging run of
  `bench-vm-startup.mjs` ends with its throwaway user kept (named on stderr
  as `cleanup_needed_user=`), no provider resources, and exit status 1; the
  measurements are still written. The users this session left that way were
  removed by hand with the server key after verifying they owned nothing.

## 12. Limitations

- One vantage point (a Mac in the same region as the provider's API), one
  day; provider numbers may differ by region and load. Production runs are
  n=3, enough to bound the shape, not to state a p95.
- The click-to-frame UI time was not measured on a GUI; the Mac phases come
  from PR #12739's Debug-build trials and source reading.
- Axiom per-stage spans were not queried (token rejected); Server-Timing on
  create and the benchmarks stand in.
- Staging and production ran the same image but different deployments and
  databases; production attach and exec were ~0.5 s slower at the median in
  this session, which the telemetry attributes to route cold starts.
