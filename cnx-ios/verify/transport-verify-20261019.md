# Transport verification, 2026-10-19 (fresh verifier)

Status: IN PROGRESS. Partial results are pushed as they land.

Under test: `origin/feat-cnx-ios` at `90375ce5e11c` (WireGuard path order
direct UDP, TURN over UDP, TURN over TLS on 443; TeamHub relay retired;
WireGuard roaming; browser video on the WebRTC track or the WireGuard RTP
lane; dev Worker API 0.9.0).

## Rig

- Mac: fleet build of `90375ce5e11c` (job `b65d313ac0f91b52bbb59726`, tag
  `cnx-e2e-90375ce5`). Its bundled `cnx-hostd.version` names commit
  `90375ce5e11c240c9acdd97ce61085019c8e3890` (key `7d66d8c1edf18a4d`). An
  unmodified copy runs hidden (`open -g -j -n`) on `mini-cmuxs-mac-mini-3`;
  every rig setting goes in through `open --env`; the bundle and its
  Info.plist are never edited or re-signed.
- Phone: the Demo configuration of `90375ce5e11c`, built on the same mini
  (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`), in one headless iPhone 17 Pro
  simulator (iOS 26.5) on the same mini.
- Backend: the dev Worker (API 0.9.0) and Cloudflare TURN.
- Driver: `verify/e2e/transport_verify.py` (this branch). Every phone action
  is a tap or typed text in the app's UI: Settings > Transport for the
  transport and the Developer toggles, the terminal composer for commands,
  the browser's address bar for pages, the toolbar for Back and Forward.
- Evidence (videos, screenshots, logs; git-ignored): on the mini under
  `~/cnx-tv/cnx-ios/verify/evidence/2026-10-19/transport-verify/`.

## Rig notes and load

- `open --env` reached the rig app's process for every key (checked with
  `ps eww`): `CMUX_NEXT_CONFIG_FILE`, `CMUX_AUTH_CREDENTIALS_FILE`,
  `CMUX_NEXT_IPHONE_PAIRING_SEED`, `CMUX_SHELL_INTEGRATION_DIR`,
  `CMUX_BUNDLED_CLI_PATH` (the last two override the fleet paths baked into
  `LSEnvironment`). No Keychain prompt; cnx-hostd started at once.
- Both allowed minis were heavily loaded by CI during the run
  (mini-cmuxs-mac-mini-3: 1-minute load 8 to 320; mini-cmux11s-mac-mini: 50 to
  350 at the same time). The laptop stayed at 12 to 27 (nothing of this run
  runs on it). Each row below carries the mini's load at its start. At loads
  over about 150 the simulator's input injection (`axe tap`) timed out after
  25 s, and once (18:24) the simulator's render server spun at 100 % CPU and
  the device would not shut down; it was killed, deleted, and the run went on
  in a new simulator (signed in again through the UI). Rows recorded in
  those windows were rerun.
