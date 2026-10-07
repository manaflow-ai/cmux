# cmux next: automation bench (browser use and computer use, one scoreboard)

Design, 2026-10-04. Owner: the agent automation lead (CU4). The browser-use leg follows the harness design from the cmux-browser lane (coordinator, 2026-10-04). Related: automation-lease.md, computer-use.md, browser-host.md section 5 (conformance and perf gates), spec/browser-use.md "Benchmarks" (Online-Mind2Web subset, public per-task logs, no self-judged scores).

## Goal

One harness measures agent browser use and computer use on the same surfaces users get, and gives one scoreboard per pin. It answers: is cmux at Aside, the ChatGPT agent and sky-cua quality for speed, reliability and not stealing focus?

## Two levels

1. **Primitive bench, no model.** Scripted calls against fixtures: snapshot, click, type, scroll, drag, wait, screenshot. It measures latency (p50, p95) and effect rate checked by an independent oracle. Cheap, deterministic, and runs on every pin.
2. **Task bench, with a model.** Online-Mind2Web-style tasks. A model drives the REPL or MCP tools until it finishes or times out. A programmatic predicate scores the result.

## Task format (both levels)

```
task {
  id, domain: browser | desktop, level: primitive | task,
  start: {url} | {app, fixture},            // snapshot copy, local fixture site, or fixture app
  goal,                                      // natural language (task level) or a script (primitive level)
  check: {kind: dom | url | state | ax | file | pixel, predicate},   // programmatic success
  rubric?,                                   // optional human rubric, never the score
  timeout_s, live: false                     // live-web tasks are marked flaky and scored apart
}
```

## Runner rules

- It drives the agent surface users get: `cmux repl` (browser and desktop domains), the host MCP tools, or `cmux-cua` MCP. No private test hooks.
- Every task gets a fresh profile (browser) or a fresh fixture app instance (desktop). Seeds are fixed. Timeouts are enforced. Retries are 0 for scoring.
- Fleet Macs only. GUI legs run on cmux-lawrence-2 (or another granted fleet Mac), never on Lawrence's laptop. Sessions run in parallel, each isolated, with a separate lease and cursor per session.
- Every step keeps a trace and a screenshot. Failures keep the full trace.
- The driver can be swapped: `browser-host` (headless Chromium, then in-app WebKit/CEF after step c), `cua` (cmux-cua), and baselines where available: `codex-cua` (Codex Computer Use / Sky, which is granted on cmux-lawrence-2) and `aside repl`.

## Outputs per run

Success rate, steps, wall time, token cost (task level), and a failure category: `nav`, `ref_stale`, `wait`, `input`, `policy_block`, `focus_stolen`, `not_landed`, `timeout`. Primitive level also gives latency p50/p95 per primitive, the effect rate, and the focus-preserved rate (the frontmost app and key window did not change). Results are written as JSONL per run plus one summary table per pin, kept under `artifacts/automation-bench/<pin>/`.

## Fixtures (first set)

Desktop: a native AppKit form app, a SwiftUI app, an Electron app (the `click-recovery` fixture from cmux-cua PR 29), a Chromium window, and TextEdit. Browser: local fixture sites from tests/browser-parity, plus snapshot copies of about 20 Online-Mind2Web tasks.

## Baselines known today (not measured by this bench yet)

- cmux-cua, Codex app window (cmux-cua PR 29 baseline): AX-only snapshot p50/p95 86/103 ms, screenshot+AX 351/367 ms; Electron background clicks rendered 0 of 20 before PR 29.
- cmux-cua agent calls: 12.6 percent failed, 2026-09-20..29.
- Classic browser REPL (PR 17256): 0 worse than Aside/ChatGPT in 156 differential cases; snapshot faster than a Playwright MCP server at p50.

## Blockers

- cmux-lawrence-2 TCC: `com.cmuxterm.cua` has Accessibility denied and no Screen Recording (system TCC.db, 2026-10-04). Asked through the coordinator. Until it is granted, the desktop leg can only run the `codex-cua` baseline.
- A tagged cmux-next helper has the same bundle id but a different signature from the Developer ID helper, so it may need its own grant.

## Steps

| Step | Content | Verification |
| --- | --- | --- |
| b1 | task schema, scorer, JSONL writer, summary table; unit tests (bun) | local bun test |
| b2 | primitive driver `cua` (cmux-cua MCP over stdio on the fleet Mac) and fixtures; oracle (pixel diff + AX value + frontmost app) | live run on cmux-lawrence-2 after the TCC grant |
| b3 | baseline drivers `codex-cua` and `aside repl` | live run on cmux-lawrence-2 |
| b4 | browser leg: `browser-host` driver on headless Chromium, then in-app tabs after step c | fleet run |
| b5 | task level: model loop over `cmux repl`, Online-Mind2Web snapshot subset, public per-task logs | fleet run |
