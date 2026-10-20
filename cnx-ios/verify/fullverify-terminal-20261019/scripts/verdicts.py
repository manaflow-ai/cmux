import json
E = "fullverify-terminal-20261019"
P, F, B = "PASS", "FAIL", "BLOCKED"
rows = []
def r(i, v, note): rows.append((i, v, note))
NT = "blocked (needs tool)"
# --- T-REND
r("T-REND-01", B, f"{NT}: G-09 phone text export and G-13 render-suite do not exist")
r("T-REND-02", B, f"{NT}: G-13 render-suite")
r("T-REND-03", B, f"{NT}: G-13 render-suite")
r("T-REND-04", B, f"{NT}: G-13 render-suite")
r("T-REND-05", B, "cursor-vs-Mac pixel check not built; not measured")
r("T-REND-06", B, "`top` exit restored the shell screen and seq 1-300 scrollback (shots/tui-quit.jpg); entry was not recorded and no M-ROWS id count")
r("T-REND-07", B, "per-TUI cell diff not built; Codex and Claude produced no output (see T-AGENT)")
r("T-REND-08", B, "`top`: 0 black frames over 4 keyboard shows and 4 hides (tui-top.motion.json, 30-67 s); the Codex half is blocked. A separate black run over `top` came from a reattach (T-LIFE-17)")
r("T-REND-09", P, "new and short sessions show the prompt on row 0 under the status bar, with no blank rows above (shots/newtab.jpg, fv-open)")
r("T-REND-10", F, "keyboard down: last row 0.67 pt above the composer in 2449/2449 frames (s1-follow-kbdown.pin.json). Keyboard up: the row is pinned at 0.67 pt (328/328), but an iOS **AutoFill** pill sits over the left part of the last two terminal rows in 67/67 sampled seconds (D3)")
r("T-REND-11", B, "light mode and AX5 not run")
# --- T-FOLLOW
r("T-FOLLOW-01", F, "the cursor row is pinned to the composer: gap 0.67 pt in every frame, keyboard down (2449 frames) and up (328 frames). Keyboard up, the AutoFill pill covers the newest rows' left 20-140 pt in every sampled frame (D3)")
r("T-FOLLOW-02", F, "keyboard down, stream20 4 min: 0 down moves, 0 reversals (s1). Keyboard up, stream20 66 s: 297 spontaneous reversals, from 1-row one-frame jumps (s2b-follow-kbup.motion.json; D1)")
r("T-FOLLOW-03", F, "46 one-frame 1-row (16 pt) jumps in 66 s keyboard up (s2b), 11 in 15 s keyboard down after Jump to bottom (s3b-jump.motion.json). In each, the new row is drawn without the 2-line live area; the next frame restores it (shots/kbup-follow-tornframe-2.34s.png; D1)")
r("T-FOLLOW-04", F, "0 black frames (s1, s2b, s3b), 0 M-ROWS foreign frames; the 46 + 11 torn-frame flashes above fail the M-MOTION flash part. Real Codex not run")
r("T-FOLLOW-05", P, "while reading: button visible in 22/22 AX polls over 60 s; following: not visible (kb-up and after-jump polls). Poll period 2 s, so the 300 ms fade window is not resolved")
r("T-FOLLOW-06", B, "stream20 keyboard up: lag p50 -0.05 s, p95 -0.00 s, so about +0.01 to +0.06 s after the +0.064 s mini clock offset (s2b-follow-kbup.rows.json). stream1m not run")
# --- T-SCROLL
r("T-SCROLL-01", B, "stream20: 0 px read-row drift for 63 s after deceleration ended (full-res motion 5.4-69 s: 0 moves; rows.py 0 drift after 5.3 s; s3b-hold.*). stream1m and real Codex not run")
r("T-SCROLL-02", B, "s3b reading hold: 0 foreign, 0 black; under the 5 min per path minimum")
r("T-SCROLL-03", F, "a page at rest never moved while reading (0 moves in 63 s), but following produces spontaneous reversals with no finger (297 in s2b, 252 in s3b-jump; D1)")
r("T-SCROLL-04", P, "reading stayed reading for 63 s while stream20 appended: 0 page moves, Jump button 22/22 polls (s3b-hold). AX + motion, not M-FRAMELOG")
r("T-SCROLL-05", B, f"{NT}: S-FLING finger tracking")
r("T-SCROLL-06", B, f"{NT}: M-FRAMELOG (G-04)")
r("T-SCROLL-07", B, f"{NT}: S-FLING")
r("T-SCROLL-08", B, "flings toward a streaming bottom not run")
r("T-SCROLL-09", P, "Jump to bottom tapped while deceleration was still running (3-4 pt/frame at 94.98 s): page at the live bottom 17-33 ms after the tap, in one step, then following (s3b-jump.motion.json, 93.2-97 s). The first jump (87.43 s) did the same. 0 foreign frames")
r("T-SCROLL-10", B, "hist10k top reach not run")
r("T-SCROLL-11", B, f"{NT}: S-SWEEP")
r("T-SCROLL-12", B, "`top`: 0 px page scroll over 10 vertical drags (tui-top.motion.json). vim, less, htop, Codex, Claude and mouse reporting not run")
r("T-SCROLL-13", B, "after `top` quit, the prompt is on the composer with history above (shots/tui-quit.jpg). The 300 ms timing was not measured")
r("T-SCROLL-14", B, "M-SIZELOG not collected")
for i in (15, 16, 17, 18): r(f"T-SCROLL-{i}", B, "not run")
# --- T-INPUT
for i in (1, 2, 3): r(f"T-INPUT-0{i}", B, f"{NT}: real-link echo probe G-08")
r("T-INPUT-04", B, f"{NT}: S-TYPE-INTEG")
r("T-INPUT-05", B, "^C from the key bar stopped a stream20 flood (keys.json); timings not measured")
r("T-INPUT-06", B, "single-line composer pastes + Send arrived (10+ commands); 50-line and 10 KB pastes not run")
r("T-INPUT-07", B, "the rig's term_keys step failed on its own locator (an off-screen grid Done matched); the 60-key table was not run")
r("T-INPUT-08", B, "not run")
r("T-INPUT-09", B, "flick = exactly 1 arrow in 5/5 (20 required); a 1.2 s hold repeats (8 columns); 0 repeats after release in 3/3 (keys.json, joystick-hold.json). Rate and first-repeat delay not timed")
r("T-INPUT-10", B, "^C visible at rest; key gaps 6.0 pt at rest (esc/ctrl/^C/tab/⇧tab/↑ AX frames). Gaps after 10 swipes and the 30-tap hit test not run")
r("T-INPUT-11", B, f"{NT}: G-18 HID")
r("T-INPUT-12", B, "IME not run")
r("T-INPUT-13", F, "the shell composer offers AutoFill: the system AutoFill pill shows over the terminal whenever the composer has focus (67/67 sampled seconds; D3). Autocorrect and capitalisation were not separately measured")
r("T-INPUT-14", B, "attachments not run")
r("T-INPUT-15", B, "not measured")
r("T-INPUT-16", B, "not run")
r("T-INPUT-17", F, "with the Mac app dead (crash at 19:15:42), a command composed and sent at 19:19:46 showed no pending or refused state (the composer cleared as if sent). It **ran on the Mac at 19:35:09, 15.4 min later**, after the Mac app relaunch; 4 later probe echoes cannot be traced (probe-send.json, life13-mac-relaunch.json; D5)")
# --- T-SEL
r("T-SEL-01", B, "long-press + Copy put the exact word on the pasteboard in 10/10 single-row selections (selection10.json); handles across rows and into scrollback not exercised")
for i in range(2, 7): r(f"T-SEL-0{i}", B, "not run")
# --- T-SIZE
for i in range(1, 10): r(f"T-SIZE-0{i}", B, "M-SIZELOG (terminal-sizing log) not collected" + ("; 0 black frames over 4 keyboard shows and 4 hides over `top`" if i == 6 else ""))
# --- T-LIFE
r("T-LIFE-01", B, "cold open of an existing never-opened tab not timed")
r("T-LIFE-02", B, "not measured")
r("T-LIFE-03", F, "grid → card, first frame of the full terminal after the tap returned: 0.76, 0.06, 0.07, 0.06, 0.05, 0.06 s (n=6; tabs-a-grid.motion.json). p95 = 0.76 s > 150 ms. Tap-return timing undercounts")
r("T-LIFE-04", B, "not run")
r("T-LIFE-05", B, "not run")
r("T-LIFE-06", P, "terminate + launch mid-stream: the app's first frame is the dimmed saved frame with 'Connecting to cmux11's Mac mini…'; live 0.65 s later; no blank frame (life-d-relaunch.motion.json, shots/relaunch-7.5s.jpg). Note: the saved frame was from an earlier state, not the pre-kill frame. Simulator launch overhead 3.9 s is excluded")
r("T-LIFE-07", B, f"{NT}: G-15")
r("T-LIFE-08", P, "kill -9 cnx-hostd mid-stream: 0 black frames over 27 s, no error text, held frame kept (life-e-hostd-kill.motion.json; n=1)")
r("T-LIFE-09", B, "the reconnect took longer than the recording (T-LIFE-12)")
r("T-LIFE-10", B, f"{NT}: M-INTEG")
r("T-LIFE-11", B, "no working agent")
r("T-LIFE-12", F, "hostd killed 03:29:01.0, restarted 03:29:02.0, signaling up 03:29:02.66; the phone's first offer timed out ('answer failed … timeout') and the link came up at 03:29:27.76, **25.1 s after hostd was listening**. The tab read 'Reattaching…' throughout (life-de.json; D2)")
r("T-LIFE-13", F, "the Mac app died (DEBUG watchdog assert, mac-crash-191542.ips); the phone showed 'Reattaching…' for 20 min, never offline (shots/mac-crashed-phone.jpg). After the relaunch the tab was live 2.3 s after the app was up (pass part). D4")
r("T-LIFE-14", B, "not run")
r("T-LIFE-15", B, "relay paths not run")
r("T-LIFE-16", B, "not run")
r("T-LIFE-17", F, "two Worker socket resets (02:11:09, 03:36:54.8): each time the phone built a **second link** while the first was still up (old link died later by 'keepalive timed out') and the terminal reattached. Over `top` this blanked the terminal (cursor only) for 11 frames at 60 fps, then painted a partial screen (tui-top 13.40-13.57 s, shots/tui-reattach-blank-13.25s.jpg; D2)")
# --- T-TABS
r("T-TABS-01", F, "while the grid is open the card never updates: card last row 78 while the Mac went 143→201 over 2.4 s; 331 while the Mac went 405→476 (tabs-ab.json). The card is a snapshot, more than 2 s old and frozen")
r("T-TABS-02", B, "not measured")
r("T-TABS-03", B, "6 shrink/expand cycles while streaming: 0 black frames (tabs-a-grid.motion.json); reflow and position error not measured")
r("T-TABS-04", B, "label OCR band not run")
r("T-TABS-05", F, "inherits T-LIFE-03 (p95 0.76 s)")
r("T-TABS-06", F, "New Terminal from +: prompt visible 5.59 s after the + tap, about 4.5 s after the 'New Terminal' pick (life-c.json); threshold p95 ≤ 1.5 s. The + button also lost its accessibility label between grid opens (None vs 'New Tab')")
r("T-TABS-07", B, "refused create not reproduced")
r("T-TABS-08", B, "a running program (python3 stream20): confirmation 3/3 ('Close “e2e-t1”?' / 'Still running: python3.14.'), Cancel kept the tab 3/3; the ask appears 2.1-2.4 s after the tap. An idle shell closed with no ask (1/1); its card was gone 4.4 s after the tap. Codex part blocked")
r("T-TABS-09", B, "not run"); r("T-TABS-10", B, "not run"); r("T-TABS-11", B, "not run")
r("T-TABS-12", B, "Feed needs a working agent"); r("T-TABS-13", B, "not run")
r("T-TABS-14", F, "on the zoomed terminal page the AX tree exposes 'Close e2e-t1' (372,0), the grid's 'Done' and 'New' (y 2536, off screen) and 'More' (y 1814), all hidden controls (D7)")
# --- T-AGENT
for i in range(1, 14):
    extra = ""
    if i == 10: extra = "; substitute 60-min stream20 load: footprint 116→140 MB peak, growth after 10 min 1 MB, slope 0.27 MB/10 min (mem60-summary.json)"
    if i == 11: extra = "; substitute: 12.3 % avg while streaming (slope -0.04 %/10 min), 2.5 % idle following (mem60-summary.json)"
    if i == 12: extra = "; substitute: cnx-hostd RSS 28→37 MB, daemon 88→208 MB over 68 min; 2 'keepalive timed out' link downs from the duplicate-link reattaches (D2)"
    r(f"T-AGENT-{i:02d}", B, "no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl)" + extra)
# --- T-LOAD
for i in ("01", "02", "03", "04", "05", "06", "07", "CAP-a", "CAP-b", "NET", "MEM"):
    r(f"T-LOAD-{i}", B, {"NET": f"{NT}: netsim G-11", "MEM": f"{NT}: G-16"}.get(i, "load matrix not run (only stream20)"))
r("T-LOAD-THERM", B, "device only")
for i in range(1, 12): r(f"T-DEV-{i:02d}", B, "needs device (no real-phone verification was asked for)")
# --- T-REG
for x in "abcdef":
    v, n = B, "red-on-old-SHA runs not done (G-17)"
    if x == "b": v, n = F, "the mechanism reproduces on the new SHA with a substitute load: keyboard up, following stream20 (a Codex-like live area), the live area shifts by a row for one frame, 46 times in 66 s (D1). Green on the new SHA not met"
    r(f"T-REG-1259-{x}", v, n)
for x in "abcde":
    v, n = B, "red runs not done (G-17)"
    if x == "a": v, n = F, "its criterion (T-SCROLL-03/T-FOLLOW-02, 0 reversals without a finger) fails on the new SHA: 297 spontaneous 1-row reversals in 66 s"
    r(f"T-REG-1337-{x}", v, n)
for x in "abc":
    v, n = B, "red runs not done (G-17)"
    if x == "a": v, n = F, "its criterion T-TABS-01 fails on the new SHA: the grid card is stale and frozen while the grid is open"
    r(f"T-REG-1350-{x}", v, n)
for x in ("D1", "D2", "D3", "D4", "D5", "R32", "R34", "R35", "R41", "R42", "B1", "OPEN"):
    n = "red runs not done (G-17)"
    if x == "D3": n += "; new SHA: hostd kill showed 0 blank frames and no error text (1/1)"
    if x == "R32": n += "; new SHA: 0 black frames over 4+4 keyboard changes over `top`"
    if x == "OPEN": n = "20 of 20 consecutive scroll_while_streaming runs not done"
    r(f"T-REG-{x}", B, n)
r("T-ADV-01", B, "S-AGENT-CODEX unavailable; about 3 h of mixed real-link use on stream20 instead, findings D1-D7")
r("T-ADV-02", B, "stream1m gesture spam not run")
assert len(rows) == 162, len(rows)
assert len({x[0] for x in rows}) == 162
cnt = {k: sum(1 for x in rows if x[1] == k) for k in (P, F, B)}
json.dump({"counts": cnt, "rows": rows}, open("/tmp/fvterm-gen/rows.json", "w"), indent=1)
print(cnt)
