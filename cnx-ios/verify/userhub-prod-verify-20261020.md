# Per-user hub on production: adversarial verification (2026-10-20)

Target: production Worker `cnx-ios-api-prod` (https://cnx-ios-api.cmux.dev, API 0.10.0, deployed
from `feat-cnx-ios-userhub` @ `0f6b3e64007`, PR manaflow-ai/cmux#22260). The bug under test is that
teammates saw the user's Mac in their iOS app. After the change, each person should see only their
own Macs.

Verifier: a fresh agent that wrote none of the change. The run used the real production backend and
the real link (WebRTC between two different Mac minis). No mocks and no loopback.

## Verdict

| # | Check | Result |
| --- | --- | --- |
| 1 | A sees A's Mac online in Workspaces (Mac filter) and the terminal works | **PASS** (Production build plus the verifier harness, below) |
| 2 | B sees no Mac of A anywhere, with no A name anywhere | **PASS, but not in a shared team.** A and B could not be put into one team (see "What could not be verified") |
| 3 | B's token against the API: no A devices; hello/presence never name A's Mac; signal to A's Mac is `not_owner` | **PASS** for two users in different teams. The shared-team case is not verified |
| 4 | Old-client sanity: A's phone reconnects after both apps relaunch | **PASS**, with one observation (O1) on the 2026-10-13 hostd |
| 5 | Production Worker logs during the run | **PASS**: 4 windows, about 300 events, 0 exceptions and 0 error logs |

**The colleague scenario itself (A and B in the same Stack team) is NOT PROVEN live.** Everything
the run could reach holds: every cross-user path is refused, and nothing of A reaches B. But the
exact situation that caused the bug, teammates sharing a team, could not be set up with test
accounts on production.

## Setup

| Part | What ran |
| --- | --- |
| Accounts | Two **new** production Stack password accounts, created for this run with the public sign-up (`credential_enabled`, `sign_up_enabled`): A = `cnx-userhub-a-20261020@test.cmux.dev` (user `735fc0a4-…`, auto team `63d9315c-…`), B = `cnx-userhub-b-20261020@test.cmux.dev` (user `40ef38e5-…`, auto team `2d1df2d2-…`). No existing prod test account was reachable: `op` was signed out, and the `~/.secrets` test logins belong to other backends' own JWTs, not Stack. The credentials are in `~/.secrets/cnx-ios-userhub-verify/` (0600) |
| iOS app | `origin/feat-cnx-ios` `3e6a2b56eff`, configuration **Production** (bundle `dev.cmux.cnx.prod`, `CNXAPIBase=https://cnx-ios-api.cmux.dev`, production Stack project), `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, Xcode 26.6 on `mini-cmux7s-mac-mini`. `check-production-binary.sh` passed. CnxFFI.xcframework was built from the same SHA on `mini-cmuxs-mac-mini-2`, and its generated `CnxFFI.swift` is byte-identical to the committed one |
| Simulator | One headless iPhone 17 Pro, iOS 26.5, on mini-cmux7s, driven with AXe (accessibility and HID taps) and `simctl io`. Nothing on the laptop took focus |
| A's Macs | `run-host.sh --prod --team 63d9315c-…` on `mini-cmuxs-mac-mini-2`, signed in as A: cnx-hostd, cmux-tui and acpmux built from `3e6a2b56eff`. Mac 1 "VerifyA Mac mini-2"; Mac 2 "VerifyA Mac two" (a second host, so the Workspaces Mac filter renders, since it needs at least 2 Macs). For check 4, Mac 2 ran the **2026-10-13 cnx-hostd** (pre-0.10, an old client) |
| Link | WebRTC, direct path between mini-cmux7s (phone) and mini-2 (Mac) |

### Verifier harness (deviation; not pushed, not shipped)

A Production build cannot be driven by a test account on a simulator as shipped:

1. **Sign-in.** Production offers only email code and OAuth. `test.cmux.dev` has no MX, so no
   code arrives, and the password auto-login is DEBUG-only. The harness adds, under `#if !DEBUG`,
   `CNX_VERIFY_STACK_EMAIL`/`CNX_VERIFY_STACK_PASSWORD`. It awaits `awaitBootstrapped()`, then
   calls `AuthCoordinator.signInWithPassword` only when the app is signed out.
2. **Pairing keys.** Production requires a Secure Enclave key (`PhoneKeys` throws `unavailable`
   outside DEBUG). The simulator has none, so pairing fails ("Pairing failed: unavailable") and
   every terminal attach fails with `no-link`. The harness uses DEBUG's software P-256 key when
   `CNX_VERIFY_SOFTWARE_KEYS=1` is set.

Everything else (Stack project, Worker, transport, UI) is the Production configuration. The patch
is at `~/cnx-ios-builds/20261020-userhub-prodverify/harness.patch` (45 lines).

## Evidence

Media (gitignored, local): `~/cnx-ios-builds/20261020-userhub-prodverify/sim/` holds the
screenshots and 4 recordings. Text evidence is in the same folder; none of it contains tokens, and
the TURN credentials are redacted.

| Check | Evidence |
| --- | --- |
| 1 | `sim/c1-A-mac-online.mp4`; `c1-01-A-mac-online.png` (connect screen: "VerifyA Mac mini-2 is online"), `c1-03-A-workspaces.png`, `c1-04-A-mac-filter.png` (filter lists both A Macs, "2 of 2 Macs online"), `c1-06-A-terminal.png` (prompt from `cmux@cmuxs-Mac-mini-2`), `c1-07-A-terminal-echo.png` (`echo userhub-$((6*7)) $(whoami)` gives `userhub-42 cmux`), `c1-08-A-settings-devices.png` |
| 2 | `sim/c2-B-sees-nothing.mp4` (A signs out in Settings, B signs in on the same simulator); `c2-03…c2-13*.png`; `c2-B-ui-dumps.txt` (11 accessibility dumps: connecting, Home, Workspaces, Feed, Settings, Settings → Devices, sidebar, Home filter, New Workspace, Chief). A grep for `VerifyA|abdulaziz|userhub-a|<A user id>|<A team id>|<A Mac ids>|<A phone id>|mini-2` finds nothing |
| 3 | `c3-B-api-probe.txt`, `c3-B-presence-socket.txt`, `c3-A-control.txt`, `c3-A-presence-socket.txt`, `api-B-early.txt` |
| 4 | `sim/c4-A-relaunch-reconnect.mp4`, `sim/c4b-relaunch-old-hostd.mp4`, `c4-01-A-after-relaunch.png`, `c4-05-A-terminal-after-relaunch.png` (`relaunch-ok-42`), `c4-06-A-old-hostd-mac.png`, `c4-not-owner-timeline.txt` |
| 5 | `c5-tail1…4-summary.txt` |
| Cleanup | `cleanup-devices.txt` |

## Results in detail

### 1. A (PASS)

- The connect screen turned "VerifyA Mac mini-2 is online" within a second of the host starting.
  hostd logged `link up … kind=WebRtc path=Direct`.
- Workspaces showed A's `cnx-demo` workspace. With the second Mac, the Mac filter lists exactly "All
  Macs", "VerifyA Mac mini-2" and "VerifyA Mac two".
- Terminal over the link: the command typed in the composer came back, `userhub-42 cmux`.

### 2. B on the same simulator after A signed out (PASS, different teams)

- B's phone registered with **new** device ids (`660a9558…`, `a9f38f36…`). A's `74cf182f…` is not
  reused across accounts.
- On every screen visited (connecting, Home + Home filter, Workspaces, the New Workspace Mac
  picker, Feed, Settings, Settings → Devices "No Macs yet", sidebar with only B's team "No Macs
  yet", Chief), nothing of A appeared. Neither did "Abdulaziz", which is expected because the user's
  own account was never involved.
- Storage after the switch: A's per-account keys (`cnx.live.mac.<A team>`, `cnx.workspaces.macFilter.<A
  team>`, `cnx.lastTabByWorkspace`) sit only inside the `cnx.account.<A user>` stash. That is the
  intended restore-on-sign-in design. Only ids are stored there, no Mac names, and B's session never
  reads it.

### 3. API with B's token (PASS for different teams)

| Probe (B's token) | Answer |
| --- | --- |
| `GET /v1/me/macs`, `GET /v1/me/devices`, `GET /v1/teams/<B team>/macs`, `GET /v1/teams/personal-<B>/macs` | Only B's own probe phone; no Mac, nothing of A |
| `GET /v1/teams/<A team>/macs`, `/teams/personal-<A>/macs`, `/teams/<A team>/hub`, `/teams/personal-<A>/prefs` | 403 `not_member` |
| `POST /v1/devices` into A's team | 403 `not_member` |
| `POST /v1/devices` claiming A's Mac id / A's phone id (in B's team) | 403 `not_owner` (no hijack) |
| `DELETE /v1/devices/<A Mac>`, `POST …/<A Mac>/notify`, `DELETE …/<A phone>/push` | 403 `not_owner` |
| `POST /v1/me/bootstrap {teamId: personal-<A>}` | `macs` part `not_member`; `myMacs` empty |
| WS upgrade `signal?deviceId=<A Mac>` in A's team / A's personal space / B's team | 403 `not_member` / `not_member` / `not_owner` "register this device first" |
| B's own socket: `hello` | `{"macs":[]}` |
| B signals A's Mac, A's phone, and a random UUID | `not_owner` for all three, with the same message, so the refusal does not reveal that A's devices exist |
| B signals with `from` = A's Mac id | `bad_request` "from must be your deviceId" |
| B's socket open 30 s while A's Mac 2 went offline and came back | B received nothing. A's socket, as positive control, received `presence` offline and then online |
| A's hosts' logs | No frame from B's device or sessions reached either A Mac |

### 4. Relaunch (PASS)

- I signed B out, stopped and restarted both A Macs (Mac 1 current hostd, Mac 2 the 2026-10-13
  hostd), and launched the app as A. Both hosts logged `signaling connected` (the old client works
  with the user hub). The app restored A and showed "Connected" to Mac 1. A new workspace from the
  phone opened a terminal: `relaunch-ok-42`.
- Mac 2 (old hostd) showed "Online · Connected" and its link came up.
- I relaunched the app alone three more times while it was linked to the old-hostd Mac. Twice it
  relinked in about 1.5 s; once it took 27.7 s (O1).

### 5. Worker logs (PASS)

`wrangler tail cnx-ios-api-prod`, 4 bounded windows covering checks 3 and 4: about 300 events, 0
exceptions, 0 `unhandled` logs and no 5xx answers. `canceled` outcomes are closed WebSockets.

## Defects and observations

**D1, verification gap (not the hub): a Production simulator build cannot pair, so it has no
terminal.** `PhoneKeys` has no Secure Enclave on the simulator and throws `unavailable` outside
DEBUG. The app shows "Pairing failed: unavailable", and every terminal shows "[Not connected to the
Mac]" (`attach … no-link`) even though the link is up.
Repro: build `--config Production`, install on any simulator, sign in, link a Mac, open a
workspace. This blocks any Production-config simulator E2E of the terminal, and prod builds can only
be checked on devices. Suggested fix: a non-shipping verification configuration or a test-only key
provider; this run used a harness for it.

**O1, old hostd (2026-10-13) after a phone relaunch, seen 1 of 3 times.** The first dial got no
answer in 25 s (`timeout`). The hub then refused the old hostd's late frames for that ended session
with `not_owner`. The old hostd treated those refusals as failing the new session and sent `bye`
("refused by the backend: not_owner: not allowed to signal this device"). The third dial connected
(27.7 s total). The current hostd never showed this. This matches the 0.9.0 rule that clients fail
a dial only on an error for their own session, which the old hostd predates. Recovery was
automatic, so this is an old-client quirk rather than a per-user hub defect. Repro, not
deterministic: link the phone to a pre-0.9 hostd, kill the app, and relaunch.
Timeline: `c4-not-owner-timeline.txt`.

**O2 (not the hub).** After cmux-tui restarts, the restored workspace (`cnx-demo`) lists with no
path and 0 tabs, and "New Terminal" in it is refused with "The Mac hasn't listed this workspace's
panes yet". A new workspace works.

## What could not be verified, and why

- **A and B in the same Stack team (the reported bug).** On production, client team creation is
  disabled ("Client team creation is disabled for this project"). Each sign-up gets its own auto
  team. An invitation's code goes only by email, `test.cmux.dev` has no MX record, and the Worker's
  invite response carries only the callback URL. No Stack server key was used, and the user's own
  account and teams were not touched. So checks 2 and 3 ran with A and B in **different** teams.
  The live shared-team gaps are:
  - teammate B getting a 200 from `GET /v1/teams/<shared>/macs` that omits A's Macs;
  - B's hello and presence on a socket in the shared team;
  - retirement of the old team hub (1012) for a team that existed before 0.10.0.

  From the code (`0f6b3e64007`, not live): `/teams/:id/macs` lists only `listOwnerMacs(me)` rows
  with `ownerUserId === me`, and the hub is named from the verified token only. To close the gap:
  put two test accounts in one production team (one invite accepted from a reachable mailbox, or
  the team added in the Stack dashboard), then rerun `c3-B-api-probe` and the B walkthrough with
  `<B team>` = the shared team.
- **The cmux-next Mac app.** The Mac side was the host package (`run-host.sh --prod`), which the
  brief allows. Mac-app-specific UI (pairing dialog, Settings → Mobile) was not exercised.
- **Unmodified Production sign-in and pairing.** Both needed the harness above. The backend,
  network path and every hub decision were real.

## Cleanup done

- Every device of A and B was deleted through `DELETE /v1/devices/:id`, and `GET /v1/me/devices`
  is now `[]` for both (`cleanup-devices.txt`).
- Hosts stopped. `~/cnx-userhub-verify` was removed on mini-2 and mini-cmux7s. The simulator was
  deleted. Access and refresh token files and raw tail logs were deleted.
- Left in place: the two Stack accounts (client-side user deletion is disabled on production) and
  their 0600 credentials in `~/.secrets/cnx-ios-userhub-verify/`.
