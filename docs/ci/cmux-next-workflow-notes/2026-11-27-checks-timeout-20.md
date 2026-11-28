# 2026-11-27-checks-timeout-20

Above `timeout-minutes: 20` in job `checks` in `.github/workflows/cmux-next.yml`, beside note-349.

2026-11-27: 20 minutes. `cmux-linux` now also serves 8-CPU runners, and the slow-checks pool
(15 min minus the 300 s tail, about 579 s) no longer fits there. The pool's work is about
4,700-5,700 CPU-seconds (the four test_cmux_next_prepush_gate.py shards grew from 226-263 s on
11-26 to 342-539 s on 11-27). 16-slot runs fit, with 0 deadline stops in runs 45958166430,
45956443787, 45954762580, 45951439266, 45942450481, 45933727339, 45924931864, 45916374738 and
45907366481. The 8-slot base-tier runs 45963179360 and 45965100592 summed 4,822 and 4,726 s and
had 96 and 80 commands stopped at the deadline, which turned "Script tests" red where the tests
pass. At 20 minutes the pool gets about 879 s: on 8 slots that is about 590-710 s of work plus
the longest shard (539 s), so it fits. Tests are not dropped.

