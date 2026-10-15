# Terminal QA round 5 (termqa, 2026-10-14 18:10 PT onward, in progress)

Input: qa-round-4.md and VERIFY-round3.md (origin/feat-cnx-ios-termverify3 `712ccf3b`).
Rig: simulator `cnx-termqa-1` on the laptop with this branch's Demo build (installed 19:57,
`e24da1c6`), `cnx-e2e-604fc689` on `mini-cmuxs-mac-mini-2` with the f18e13c9 daemon (round 4),
WireGuard + relay (G-T). Laptop load was 8-24 during this round, so there are no timing claims.

## Defects

| ID | Severity | Status | Evidence |
| --- | --- | --- | --- |
| Reconnect 7-70 s after a `cnx-hostd` kill | disruptive | **cause found and fixed (Mac app)**. Not on the rig: the rig's Mac app predates the fix | below |
| V3-2 output froze after a drop mid-stream | disruptive | **defensive fix**: the replay gate's own 2 s deadline. Not reproduced on the D4-fixed daemon | below |
| V3-3 drop during a fling loses the place | disruptive | **fixed, rig 1 of 1** | below |
| V2-3 position lost once row counts diverge | disruptive | **fixed in unit tests; rig 1 of 1** (counts 1115 -> 1118) | below |
| V3-1 black page after a second reset | disruptive | **fixed**: a second reset before the reader moves reuses the restored mark. Its trigger (the D4 double replay) is gone on the daemon | below |
| PR 20809 review | - | **findings fixed and posted** | https://github.com/manaflow-ai/cmux/pull/20809#issuecomment-6183326812 |
| D5, V3-4, rotation, V2-2/D7, V2-6, D10, D1, D6, D11, D12, unknown surface 14, T-LIFE-08, G-04 | | not started this round | |

### Reconnect latency after a hostd kill

The phone was not the slow side. Its log shows `link macOffline` within 0.1 s of every kill, and
a dial within 0.1 s of the presence `online`; every dial succeeded at once. The Mac app's
supervisor restarted hostd late. hostd's own log (`cnx-hostd.log` on mini-2) shows `starting` 7,
16, 32 and 61 s after kills spaced 13-45 s apart (round 4, 18:04-18:08). `CnxHostSupervisor`
doubles its restart backoff (1 s to 60 s), and only a run that lasted 60 s reset it. A kill more than
60 s after the last one reconnected in 2.4 s (18:12:05 -> 18:12:08.3) and 1.9 s (19:59:02 -> 19:59:04.6).

Fix (cmux `feat-cnx-ios-machost`): a run that came online and stayed online for 5 s resets the backoff, so
the next restart comes after about 1 s. A run that never comes online keeps backing off.
- Red: `f59ff1b9` (`aRunThatCameOnlineRestartsAtTheFirstDelay`). It failed in CnxHostTests
  (cmux-ci step `079b59f35374f344e50111bd`).
- Green: `3df9ff77`. The CmuxNext Swift suites (4 shards, Xcode 26.6) passed 288 of 288 suites; steps `3cc5c26d…`,
  `7afad86f…`, `ff047808…` and `81e9ad07…`.
- **Rig caveat:** the rig's Mac app was built before this fix. Space `pkill` drops more than 60 s
  apart, or the restart backoff, not the phone, sets the reconnect time.

WebRTC uses the same presence path and supervisor, so the same fix applies to it.

### V2-3, V3-1, V3-3, V3-2 (phone, `e24da1c6`; red `5411a38a`)

- **V2-3: the mark matches content, with neighbours.** `TerminalReadingMark` keeps 8 rows above the
  anchor and 48 rows from it down. It tries an exact match of the anchor's rows first. If that fails,
  every distinctive row votes for where the window now sits. The red test reproduced the verifier's
  exact log line, `835 -> 935 of 1218`: one changed row among the six used to drop the match to the
  distance from the end.
- **V3-3: a reset marks the reader in any state but following.** That includes mid-fling and mid-drag,
  read from the rows on screen. The fling stops so that the restore lands.
- **V3-1: a second reset reuses the restored mark.** When a second reset arrives before the reader
  moves, it reuses the mark it just restored and does not re-read the rows on screen.
- **V3-2: the replay gate has its own 2 s deadline.** The verifier's V3-2 log (17:24:28) shows a
  reattach reset and a `resized-event` reset 24 ms apart. After the restore, the page's bottom offset
  never changed again (12696 at 17:25:55 and at 17:26:24), so the document stopped growing. Growth is
  gated only by `TerminalReplayGate`, and before this fix only the held frame's timer could expire the
  gate. That timer is not armed under a held frame or during a scroll. The double reset is gone with
  D4, and the deadline means a stuck gate ends after 2 s.
- **Tests:** CnxKit on mini-cmux11s ran `swift test --filter 'CnxTerminalTests|CnxLiveTests|CnxTransportTests'`:
  244 tests passed. Red at `5411a38a`: 5 issues in the 4 new tests.
- **Rig, read-drop (G-T, 19:59:02):** the page was settled at row 918 of 1115. After the drop:
  `reading mark restored row 918 -> 921 of 1118`. The OCR of the top 14 rows was identical before
  and after (items 116-128).
- **Rig, fling-drop (20:00:21):** a fling was started and the kill sent at the same moment. At the
  reset: `reading mark row 690 of 1118: kept`, then `restored row 690 -> 690`. The page rests on
  items 216-220, where the fling was when the reset came, not at the live bottom or the top of history.
