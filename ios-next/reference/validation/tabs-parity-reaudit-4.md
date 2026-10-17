# Tabs grid: Safari parity re-audit 4 (independent, adversarial)

**Status: IN PROGRESS (partial results).**

Builds: app `dca437b7fa23` (Tabs scheme, Debug, mini-cmux15 slot `reaudit4`, built from a detached worktree at that commit); kit `016f87d3716f` (git archive of `Packages/iOS/CmuxTabsKit`, `CmuxTabsKitDemo`, `~/nx-ios/reaudit4-kit`). Simulator `nx-ios-reaudit4` (iPhone 17 Pro, headless). Artifacts: `~/nxios-ref/tabs-reaudit-4/` (`*-dca437b*` = app build). Safari curves: `~/nxios-ref/tabs-reaudit-3/safari/` and the Safari columns of the re-audit 3 tables.

| # | Item | Safari | Ours (runs) | Δ | Verdict |
|---|---|---|---|---|---|
| D8 | ✕ reflow (mock) | 34–41 / 119–122 / 235–246 / 338–345 ms | 3 runs: 46–48 / 121–123 / 244–246 / 355–361 | t10 +9..+11, t50 0..+2, t90 +3..+5, t99 +14..+20 ms; 4.8–5.9 pt vs Safari mean | FAIL (marginal) |
| D1 | Fling | x1 crosses 300, holds, ~1200 pt/s | 3 runs, 5→4; slower: ~1000 pt/s | 47–73 pt behind Safari at +183..+233 ms | FAIL |
| D10 | Count on ✕ / fling | frame before motion / +5..12 ms | −45 ms vs first move (3/3) / +55..+75 ms | ≈ −28 ms / +43..+70 ms | FAIL |
| D3 | Drag onset | −29..−31 pt at +100 ms | −15.6..−16.6 pt at +100 ms; no first-frame jump | 13–15 pt behind | FAIL |
| D3a | Slow drag closes? | springs back | 0 of 9 closed | — | PASS |
| 3g | Snap-back | 47 / 145–148 / 309–317 / 497–506 | crossings within −12..+13 ms | ≤ 1 frame | PASS |
| 3h | Lift scale-back | | crossings +27..+54 ms; 1.7–2.8 pt | FAIL (marginal) |
| 1a | Zoom-in | | t10–t90 within ±6 ms | PASS |
| 1c | Zoom-out | | −12..−5 ms all crossings | PASS (fixed) |
| D7 | Swipe up | | t50 −18..−29, t90 −20..−35 ms; 27–37 pt | FAIL (improved) |
| 3l | 2→1 | | t99 +16..+19 ms | FAIL (marginal) |
| D2 | Last tab | | 2.7–3.8 pt; **keyboard rises** | FAIL (regression) |
| 3i | Right rubber-band release | 47–58 / 151–158 / 316–331 / 462–476 | 3 runs: 53–58 / 174–182 / 360–378 / 453–470 | t50 +18..+27, t90 +34..+52 ms; 2.7–3.3 pt | FAIL (marginal) |
| 4b | Rubber band top | +91.3/+92.6 pt | +93.3 pt ×3; t99 +40..+54 ms; run 3 +21 ms t50 | FAIL (marginal) |
| D3-commit | Swipe 100 pt / 1 s | closes | 3/3 close | PASS |
| grab | Two swipes 0.15 s apart | 5→3 | 3/3 5→3 | PASS |
| rapid ✕ | | 5→3 | 3/3 | PASS |
| tap during zoom-out | queues; grows +470–570, full ~+770 ms | queues 3/3; grows +735–930, full +1065–1275 ms | +260..+400 ms slow | FAIL (timing) |
| swipe during zoom-out | accepted | 3/3 5→4 | PASS |
| D6b reorder | both stay, dragged card follows finger on top | left 3/3, right 3/3 reorder, but the dragged card turns into a **blank white rectangle** (every run) and the real card stays under its neighbour; **down 0/4 reorder** (menu opens, card snaps back) | FAIL (regression) |
