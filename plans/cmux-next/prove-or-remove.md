# Prove or remove, every program, by 2026-11-04 (Lawrence's decision, 2026-10-28 ~09:45Z), binding

Lawrence: "apply the Nov 4 prove-or-remove rule to every program".

Rule: every one of the 15 chrome-parity programs (p01-process ... p15-oracle), and every mechanism inside it, shows a
measured, user-visible result on an optimized build by 2026-11-04 23:59 PT, or its code is removed. No exception for
"infrastructure" without a number a person feels or a gate that already catches real regressions.

What counts as proof (one per mechanism, recorded in the switch/program table with sha, host, build, bench, numbers):
- a felt metric moved beyond the lab noise band vs the base (key-to-frame, first-5s, launch, switch-scale, memory per
  terminal, idle CPU/wakeups, frame drops, restore), on the corrected benches; or
- a correctness gate that is ON in CI/the train and has caught at least one real defect (oracle suites, sanitizers,
  guardrails), with the defect named; or
- a fix of a named user-visible bug with its red/green test.
Not proof: "infrastructure for later", counts of code or tests, a Debug-only build, a switch that is off.

Process:
1. Today: add a column to the program table and to switch-table.md: proof (link) / due 11-04 / owner. Every
   mechanism gets one owner.
2. 11-01: interim report: each program's proven, unproven, and planned-to-prove items, with net lines each.
3. 11-04: the deletion wave: one branch per program removes every unproven mechanism and its switch, red test first
   where behavior changes (a removed path must not break a proven one). Net lines must go down by at least the
   size of the removed mechanisms. The lead posts the list to cmux-ad before it lands; cmux-ad tells Lawrence.
4. The felt-queue fixes are exempt only while they are in progress; they need their proof like everything else.
5. Report the net-lines curve daily; the target is net negative from 11-04 on.
