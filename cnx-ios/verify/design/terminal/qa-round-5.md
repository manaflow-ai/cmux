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
| D5 never-opened card black | noticeable | **fixed, rig 1 of 1** (`c5b4b2ac`) | `round5/r5-d5-grid1s.jpg`: e2e-t2's card shows its rows 1 s after the grid opens |
| V3-4 / T-TABS-14 hidden controls in cards | noticeable | **fixed for ours, rig 2 of 2** (`f27e2c75`); kit-owned ones are in UPSTREAM-REQUESTS.md U8 | AX dump in the grid: 5 page elements exposed before, 0 after |
| "unknown surface 14" on every reattach | minor | **fixed** (red `86be059f`, green `c622a001`) | not re-checked on the rig: it needs a closed tab's session |
| Rotation rows (T-SIZE-04, rotation during a trip) | - | **not applicable on iPhone; needs a decision** | the app is portrait-only (`project.yml` `UISupportedInterfaceOrientations: [Portrait]`) |
| PR 20809 review | - | **findings fixed and posted; CI green except an outside reservation** | https://github.com/manaflow-ai/cmux/pull/20809#issuecomment-6183326812 and #issuecomment-6183852910 |
| V2-2/D7, V2-6, D10, D1, D6, D11, D12, T-LIFE-08, G-04 timing | | not started this round | |

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

### D5 (`c5b4b2ac`, red `cbe800df`)

The tab grid card of a tab not opened in this launch fetches its terminal's screen
(`read-screen`, which hostd's policy allows) over a short-lived `daemon` channel. The fetch
happens when the card is built, at most every 3 s, and the card shows the text in monospaced
rows. Its saved frame from an earlier launch had been a blank screen with a cursor. Once the
tab is opened, its live snapshot is used as before. Pure chooser: `TerminalCardContent`
(3 tests).

### V3-4 (`f27e2c75`)

TabsKit keeps the active page in place while the grid is open and does not lay it out again,
and SwiftUI's `accessibilityHidden` does not reach a representable's UIKit views. When the grid
opens (`prepareCard`), the page's view now gets `accessibilityElements = []`, the hidden flag,
and no user interaction; its next interactive update restores them. Rig check, 2 trips: 0 page
elements exposed in the grid, and the composer and Return come back on the page.

### Rotation

The iPhone app supports portrait only, so a rotation never happens there and T-SIZE-04 cannot be
run. Enabling landscape is a product and design decision that affects every screen. It is
listed for the user. A DEBUG geometry hook was not added, because it would be refused under a
portrait-only plist.

## Tests this round

- CnxKit on mini-cmux11s, `swift test --filter 'CnxTerminalTests|CnxLiveTests|CnxTransportTests|CnxWorkspacesTests'`:
  301 passed at `c622a001`. Note: `git archive` stamps files with the commit time, so touch
  the sources after the rsync or SwiftPM may reuse a newer build.
- CmuxNext Swift suites (cmux-ci, 4 shards, Xcode 26.6): 288 of 288 at `3df9ff77`.
- cmux-tui on rbx: clippy is clean. nextest at `e960080b` passed 5171 of 5173; the 2 failures
  were load flakes and pass alone. After the merge of `feat-cmux-next` it passed 5182 of 5183,
  with 1 flake that passes alone. The crash ratchet is ok.
- Every iOS Demo build succeeded (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, DerivedData `cnx-ios/build/dd`).

## SHAs

| Repo / branch | SHA | Change |
| --- | --- | --- |
| cmux `feat-cnx-ios-machost` | `f59ff1b9` red, `3df9ff77` | supervisor: a run online for 5 s restarts at the first delay |
| cmux `feat-cmux-next-tui-attach-size` (PR 20809) | `6bb49632` red, `e960080b`, `1a756bcc`, merge, `1071f4a0`, `9db5f180` | review fixes, ratchet, fmt |
| `feat-cnx-ios-termqa` | `5411a38a` red, `e24da1c6`; `cbe800df` red, `c5b4b2ac`; `f27e2c75`; `86be059f` red, `c622a001` | V2-3/V3-1/V3-2/V3-3, D5, V3-4, surface 14 |

## Rig state for the next verifier

- Simulator `cnx-termqa-1` (`C906E217-BD51-4BC7-82D8-584AB67695B7`), booted and headless, with the
  `c622a001` Demo build installed (binary sha256 `10e5721c5f7e5fb6…`). The app is open on
  `e2e-t1` over WireGuard + relay.
- Mac `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2, daemon f18e13c9 (round 4). Its Mac app still
  has the **old** hostd supervisor, so space `pkill -9 cnx-hostd` drops more than 60 s apart,
  or the restart backoff will dominate. The original daemon backup is still at
  `~/cnx-ios-e2e/termqa/stage-640c9d5f/cmux.604fc689.bak`.
- The PR 20809 head (`9db5f180`) adds the review fixes on top of the rig's daemon (f18e13c9). The
  rig daemon does not have them: a phone returning at a larger size is still capped there.

## Next (in order)

1. The user decides on landscape for the iPhone app: rotation rows are N/A until then.
2. V2-2/D7 (one-row jump while following), V2-6, D10, D1, D6, D11, D12, T-LIFE-08 (9-13 black
   frames on deep-history and WebRTC drops).
3. G-04 in-app frame timing (signposts and a display-link interval log), or the simulator on a
   remote Mac, so that timing rows can count.
4. Rebuild the rig's Mac app with `3df9ff77` (supervisor) and swap in a daemon from PR 20809's head.
