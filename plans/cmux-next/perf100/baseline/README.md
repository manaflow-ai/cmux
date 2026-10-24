# perf100 baseline, 2026-10-21

feat-cmux-next d8c03f5a3feb (the runner's base; the measured app is the tagged fleet build of the runner commit, which adds only scripts and docs to it). Seed 1. Full JSON per run next to each REPORT.md. Compare a lane's run with `python3 scripts/perf100/perf100.py compare --before plans/cmux-next/perf100/baseline/<host> --after <your run dir>` (same host class only).

Runs: cmux-lawrence-2 nx-remote jobs 1021-001934-588d18 (S0, S1, S3, S2 headless; runner 0ef3a1a15771), 1021-022447-c5ea87 (S2 app, S4 app, S4 headless; runner 5e67ec46d167). rbx: runner 0ef3a1a15771, release build of d8c03f5a3feb. The host is shared: load average at each run's start is in its JSON; repeat a before run next to your after run for small effects.

Caveats (also in each JSON's notes and unverified):
- S3 and S4 ran 200 workspaces x 1 terminal on cmux-lawrence-2, not 200 x 5: the shared GUI host allows a job 300 PTYs. The 1000-terminal case ran headless on rbx only.
- S4 app comes from the rerun 1021-025606-bbfb7f (runner db68ce4fa021): cold launch-to-interactive 4,233 ms, restart 2,286 ms. The tables below were made before that rerun and still show the earlier S4 app run (job 1021-022447-c5ea87, whose cold value 11.5 s included a 10 s harness wait); REPORT.md and the JSON hold the rerun.
- S2 app measures token-to-page (the agent pane's chat state), not pixels.
- rbx disk-written values are 0: that run kept state on tmpfs (fixed).
- wakeups/s on macOS is ri_interrupt_wkups; ri_pkg_idle_wkups is 0 on Apple silicon.

### cmux-lawrence-2 (MacBook Pro, 15 CPUs, 48 GB, macOS 27.0.1), shared GUI host

| scenario / phase | window s | cmux CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| S0 app / idle | 60.11 | 1.96 | 3.25 | 20.31 | 3,185 | 1,408 | 1,518 | 720 | 114 | 113 | 38 |
| S0 headless-tui / idle | 60.13 | 0.005 | 0.008 | 0.18 | 275 | 119 | 119 | 205 | 0 | 0 | 14 |
| S1 app / flood1 | 112 | 537 | 481 | 466 | 1,428 | 997 | 997 | 221 | 3,396 | 1,825 | 16 |
| S1 app / flood10 | 988 | 5,579 | 565 | 2,166 | 3,445 | 2,467 | 5,751 | 409 | 69,910 | 4,246 | 27 |
| S1 app / after | 30.11 | 199 | 662 | 17,428 | 3,470 | 2,490 | 2,491 | 413 | 3,364 | 6,703 | 27 |
| S1 headless-tui / flood1 | 95.46 | 290 | 304 | 0.71 | 348 | 261 | 341 | 68 | 3,152 | 1,981 | 3 |
| S1 headless-tui / flood10 | 1,010 | 7,005 | 694 | 1.53 | 1,253 | 698 | 924 | 229 | 86,306 | 5,129 | 14 |
| S2 app / idle | 30.11 | 0.013 | 0.044 | 7.08 | 1,495 | 755 | 756 | 433 | 0 | 0 | 37 |
| S2 app / stream | 78.04 | 25.11 | 32.18 | 426 | 1,742 | 990 | 1,298 | 453 | 16.27 | 12.51 | 37 |
| S2 headless-acpmux-10 / create | 0.74 | 0.254 | 34.47 | 224 | 164 | 63.3 | 63.3 | 55 | 7.19 | 586 | 11 |
| S2 headless-acpmux-10 / idle | 60.14 | 0 | 0 | 0 | 163 | 63.2 | 63.2 | 50 | 0 | 0 | 11 |
| S2 headless-acpmux-10 / stream | 78.11 | 4.18 | 5.36 | 345 | 180 | 77.8 | 78.6 | 52 | 7.24 | 5.56 | 11 |
| S2 headless-acpmux-100 / create | 4.29 | 4.26 | 99.22 | 392 | 1,302 | 482 | 482 | 334 | 71.14 | 994 | 101 |
| S2 headless-acpmux-100 / idle | 60.13 | 0 | 0 | 0 | 1,302 | 481 | 481 | 320 | 0 | 0 | 101 |
| S2 headless-acpmux-100 / stream | 78.73 | 92.64 | 118 | 2,946 | 1,343 | 527 | 530 | 322 | 79.85 | 60.85 | 101 |
| S3 app / create | 57.28 | 75.66 | 132 | 148 | 4,394 | 2,226 | 2,226 | 2928 | 1,959 | 2,052 | 213 |
| S3 app / idle | 60.16 | 0.027 | 0.045 | 3.04 | 4,393 | 2,024 | 2,025 | 2924 | 0 | 0 | 213 |
| S3 headless-tui / create | 16 | 7.88 | 49.27 | 71.37 | 2,942 | 1,044 | 1,044 | 2636 | 486 | 1,823 | 201 |
| S3 headless-tui / idle | 60.16 | 0.002 | 0.003 | 0.17 | 2,942 | 1,044 | 1,044 | 2636 | 0 | 0 | 201 |
| S4 app / create | 44.17 | 55.8 | 126 | 242 | 4,324 | 2,178 | 2,178 | 2931 | 1,933 | 2,626 | 213 |
| S4 app / idle | 60.14 | 0.024 | 0.039 | 2.99 | 4,324 | 1,977 | 1,977 | 2926 | 0 | 0 | 213 |
| S4 app / restart | 2.99 | 2.65 | 88.37 | 204 | 4,001 | 2,074 | 2,075 | 2851 | 1.07 | 21.4 | 213 |
| S4 headless-tui / create | 16.59 | 8.44 | 50.86 | 62.98 | 2,939 | 1,041 | 1,041 | 2636 | 477 | 1,725 | 201 |
| S4 headless-tui / idle | 60.16 | 0.002 | 0.003 | 0.17 | 2,940 | 1,043 | 1,043 | 2636 | 0 | 0 | 201 |
| S4 headless-tui / restart | 7.31 | 3.6 | 49.24 | 31.48 | 3,092 | 1,167 | 1,167 | 2625 | 145 | 1,191 | 201 |

| scenario | metric | value |
|---|---|---:|
| S0 app | disk.stop.home_mb | 242 |
| S0 app | latency.keystroke_to_glyph.max_ms | 11.98 |
| S0 app | latency.keystroke_to_glyph.p50_ms | 1.66 |
| S0 app | latency.keystroke_to_glyph.p95_ms | 5.12 |
| S0 app | stop.quit_ms | 734 |
| S0 headless-tui | disk.state_mb | 6.74 |
| S0 headless-tui | start.cold_identify_ms | 200 |
| S0 headless-tui | stop.leftover_terminal_hosts | 0 |
| S0 headless-tui | stop.shutdown_end_terminals_ms | 347 |
| S1 app | disk.stop.home_mb | 2,938 |
| S1 app | flood1.cmux_cpu_s_per_100mb | 269 |
| S1 app | flood1.cmux_disk_written_per_output_mb | 16.98 |
| S1 app | flood1.finished | 1 |
| S1 app | flood1.throughput_mb_s | 1.8 |
| S1 app | flood1.wall_s | 112 |
| S1 app | flood10.cmux_cpu_s_per_100mb | 279 |
| S1 app | flood10.cmux_disk_written_per_output_mb | 34.96 |
| S1 app | flood10.finished | 10 |
| S1 app | flood10.throughput_mb_s | 2 |
| S1 app | flood10.wall_s | 988 |
| S1 app | stop.quit_ms | 2,588 |
| S1 headless-tui | disk.state_mb | 3,062 |
| S1 headless-tui | flood1.client_socket_mb | 352 |
| S1 headless-tui | flood1.cmux_cpu_s_per_100mb | 145 |
| S1 headless-tui | flood1.cmux_disk_written_per_output_mb | 15.76 |
| S1 headless-tui | flood1.finished | 1 |
| S1 headless-tui | flood1.throughput_mb_s | 2.1 |
| S1 headless-tui | flood1.wall_s | 95.38 |
| S1 headless-tui | flood10.client_socket_mb | 4,590 |
| S1 headless-tui | flood10.cmux_cpu_s_per_100mb | 350 |
| S1 headless-tui | flood10.cmux_disk_written_per_output_mb | 43.15 |
| S1 headless-tui | flood10.finished | 10 |
| S1 headless-tui | flood10.throughput_mb_s | 2 |
| S1 headless-tui | flood10.wall_s | 1,010 |
| S1 headless-tui | start.cold_identify_ms | 143 |
| S1 headless-tui | stop.leftover_terminal_hosts | 0 |
| S1 headless-tui | stop.shutdown_end_terminals_ms | 4,335 |
| S2 app | disk.stop.home_mb | 126 |
| S2 app | latency.token_to_page.max_ms | 21.6 |
| S2 app | latency.token_to_page.p50_ms | 12.41 |
| S2 app | latency.token_to_page.p95_ms | 21.6 |
| S2 app | stop.quit_ms | 653 |
| S2 app | stream.cmux_cpu_s_per_session | 2.51 |
| S2 app | stream.cmux_disk_written_mb_per_session | 1.63 |
| S2 app | stream.sessions_ended | 10 |
| S2 app | stream.wall_s | 77.95 |
| S2 headless-acpmux-10 | create.seconds | 0.66 |
| S2 headless-acpmux-10 | disk.acpmux_home_mb | 4.26 |
| S2 headless-acpmux-10 | latency.token_to_client.max_ms | 2.12 |
| S2 headless-acpmux-10 | latency.token_to_client.p50_ms | 0.35 |
| S2 headless-acpmux-10 | latency.token_to_client.p95_ms | 0.57 |
| S2 headless-acpmux-10 | start.ready_ms | 37.1 |
| S2 headless-acpmux-10 | stream.acpmux_cpu_s_per_session | 0.418 |
| S2 headless-acpmux-10 | stream.acpmux_cpu_us_per_chunk | 310 |
| S2 headless-acpmux-10 | stream.acpmux_disk_written_mb_per_session | 0.724 |
| S2 headless-acpmux-10 | stream.acpmux_syscalls_per_chunk | 33.94 |
| S2 headless-acpmux-10 | stream.chunks | 13498 |
| S2 headless-acpmux-10 | stream.client_mb | 0.29 |
| S2 headless-acpmux-10 | stream.sessions_ok | 10 |
| S2 headless-acpmux-10 | stream.text_mb | 0.293 |
| S2 headless-acpmux-10 | stream.wall_s | 78 |
| S2 headless-acpmux-100 | create.seconds | 4.18 |
| S2 headless-acpmux-100 | disk.acpmux_home_mb | 34.9 |
| S2 headless-acpmux-100 | latency.token_to_client.max_ms | 455 |
| S2 headless-acpmux-100 | latency.token_to_client.p50_ms | 0.78 |
| S2 headless-acpmux-100 | latency.token_to_client.p95_ms | 84.87 |
| S2 headless-acpmux-100 | start.ready_ms | 37.8 |
| S2 headless-acpmux-100 | stream.acpmux_cpu_s_per_session | 0.926 |
| S2 headless-acpmux-100 | stream.acpmux_cpu_us_per_chunk | 816 |
| S2 headless-acpmux-100 | stream.acpmux_disk_written_mb_per_session | 0.798 |
| S2 headless-acpmux-100 | stream.acpmux_syscalls_per_chunk | 86.2 |
| S2 headless-acpmux-100 | stream.chunks | 113490 |
| S2 headless-acpmux-100 | stream.client_mb | 2.49 |
| S2 headless-acpmux-100 | stream.sessions_ok | 100 |
| S2 headless-acpmux-100 | stream.text_mb | 2.46 |
| S2 headless-acpmux-100 | stream.wall_s | 78.64 |
| S3 app | create.seconds | 57.18 |
| S3 app | create.terminals | 200 |
| S3 app | create.workspaces | 200 |
| S3 app | disk.stop.home_mb | 237 |
| S3 app | latency.keystroke_to_glyph.max_ms | 31.72 |
| S3 app | latency.keystroke_to_glyph.p50_ms | 9.36 |
| S3 app | latency.keystroke_to_glyph.p95_ms | 19.44 |
| S3 app | stop.quit_ms | 4,535 |
| S3 headless-tui | create.seconds | 15.9 |
| S3 headless-tui | create.terminals | 200 |
| S3 headless-tui | create.terminals_per_s | 12.6 |
| S3 headless-tui | disk.state_mb | 12.84 |
| S3 headless-tui | latency.keystroke_to_echo_headless.max_ms | 0.26 |
| S3 headless-tui | latency.keystroke_to_echo_headless.p50_ms | 0.13 |
| S3 headless-tui | latency.keystroke_to_echo_headless.p95_ms | 0.23 |
| S3 headless-tui | start.cold_identify_ms | 154 |
| S3 headless-tui | stop.leftover_terminal_hosts | 0 |
| S3 headless-tui | stop.shutdown_end_terminals_ms | 3,650 |
| S4 app | cold.launch_to_interactive_ms | 11,478 |
| S4 app | cold.quit_end_sessions_ms | 181 |
| S4 app | cold.socket_ms | 1,259 |
| S4 app | create.seconds | 44.04 |
| S4 app | create.terminals | 200 |
| S4 app | create.workspaces | 200 |
| S4 app | disk.stop.home_mb | 237 |
| S4 app | latency.launch_to_interactive.cold_ms | 11,478 |
| S4 app | latency.launch_to_interactive.restart_ms | 2,330 |
| S4 app | restart.launch_to_all_workspaces_ms | 2,340 |
| S4 app | restart.launch_to_interactive_ms | 2,330 |
| S4 app | restart.quit_keep_sessions_ms | 506 |
| S4 app | restart.terminals | 200 |
| S4 app | stop.quit_ms | 0.2 |
| S4 headless-tui | create.seconds | 16.5 |
| S4 headless-tui | create.terminals | 200 |
| S4 headless-tui | create.terminals_per_s | 12.1 |
| S4 headless-tui | disk.state_mb | 16.84 |
| S4 headless-tui | latency.keystroke_to_echo_headless.max_ms | 0.22 |
| S4 headless-tui | latency.keystroke_to_echo_headless.p50_ms | 0.12 |
| S4 headless-tui | latency.keystroke_to_echo_headless.p95_ms | 0.17 |
| S4 headless-tui | restart.start_identify_ms | 5,731 |
| S4 headless-tui | restart.stop_keep_terminals_ms | 89.2 |
| S4 headless-tui | restart.to_topology_ms | 7,100 |
| S4 headless-tui | restart.workspaces_after | 200 |
| S4 headless-tui | start.cold_identify_ms | 170 |
| S4 headless-tui | stop.leftover_terminal_hosts | 0 |
| S4 headless-tui | stop.shutdown_end_terminals_ms | 4,647 |

### rbx (AMD EPYC 9B45, Linux, release build), headless

| scenario / phase | window s | cmux CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| S0 headless-tui / idle | 60.02 | 0.01 | 0.017 | 0.18 | 237 | 84.8 | 84.8 | 194 | 0 | 0 | 14 |
| S1 headless-tui / flood1 | 38.6 | 234 | 606 | 947,143 | 211 | 187 | 187 | 54 | 0 | 0 | 3 |
| S1 headless-tui / flood10 | 36.12 | 1,044 | 2,889 | 3,452,023 | 1,071 | 922 | 926 | 228 | 0 | 0 | 14 |
| S2 headless-acpmux-10 / create | 0.14 | 0.07 | 49.78 | 12,112 | 108 | 39.3 | 39.3 | 235 | 0 | 0 | 11 |
| S2 headless-acpmux-10 / idle | 60.02 | 0 | 0 | 0 | 108 | 39 | 39 | 227 | 0 | 0 | 11 |
| S2 headless-acpmux-10 / stream | 77.94 | 2.02 | 2.59 | 1,180 | 122 | 53.2 | 53.2 | 231 | 0 | 0 | 11 |
| S2 headless-acpmux-100 / create | 0.71 | 1.02 | 144 | 56,202 | 805 | 124 | 124 | 505 | 0 | 0 | 101 |
| S2 headless-acpmux-100 / idle | 60.09 | 0 | 0 | 0 | 804 | 123 | 123 | 497 | 0 | 0 | 101 |
| S2 headless-acpmux-100 / stream | 78.04 | 165 | 211 | 64,577 | 845 | 164 | 164 | 501 | 0 | 0 | 101 |
| S3 headless-tui / create | 10.37 | 8.31 | 80.17 | 6,610 | 13,915 | 2,396 | 2,396 | 13025 | 0 | 0 | 1001 |
| S3 headless-tui / idle | 61.11 | 0 | 0 | 0.16 | 13,916 | 2,397 | 2,397 | 13025 | 0 | 0 | 1001 |
| S4 headless-tui / create | 10.87 | 8.8 | 80.97 | 6,276 | 14,173 | 2,660 | 2,660 | 13025 | 0 | 0 | 1001 |
| S4 headless-tui / idle | 61.08 | 0 | 0 | 0.16 | 14,175 | 2,661 | 2,661 | 13025 | 0 | 0 | 1001 |
| S4 headless-tui / restart | 8.22 | 9.04 | 110 | 8,570 | 2,033 | 2,007 | 2,662 | 3023 | 0 | 0 | 1 |

| scenario | metric | value |
|---|---|---:|
| S0 headless-tui | disk.state_mb | 5.33 |
| S0 headless-tui | start.cold_identify_ms | 35.2 |
| S0 headless-tui | stop.leftover_terminal_hosts | 0 |
| S0 headless-tui | stop.shutdown_end_terminals_ms | 43.8 |
| S1 headless-tui | disk.state_mb | 1,640 |
| S1 headless-tui | flood1.client_socket_mb | 834 |
| S1 headless-tui | flood1.cmux_cpu_s_per_100mb | 117 |
| S1 headless-tui | flood1.cmux_disk_written_per_output_mb | 0 |
| S1 headless-tui | flood1.finished | 1 |
| S1 headless-tui | flood1.throughput_mb_s | 5.2 |
| S1 headless-tui | flood1.wall_s | 38.59 |
| S1 headless-tui | flood10.client_socket_mb | 2,368 |
| S1 headless-tui | flood10.cmux_cpu_s_per_100mb | 52.17 |
| S1 headless-tui | flood10.cmux_disk_written_per_output_mb | 0 |
| S1 headless-tui | flood10.finished | 10 |
| S1 headless-tui | flood10.throughput_mb_s | 55.8 |
| S1 headless-tui | flood10.wall_s | 36.04 |
| S1 headless-tui | start.cold_identify_ms | 34.8 |
| S1 headless-tui | stop.leftover_terminal_hosts | 0 |
| S1 headless-tui | stop.shutdown_end_terminals_ms | 1,079 |
| S2 headless-acpmux-10 | create.seconds | 0.12 |
| S2 headless-acpmux-10 | disk.acpmux_home_mb | 3.95 |
| S2 headless-acpmux-10 | latency.token_to_client.max_ms | 0.33 |
| S2 headless-acpmux-10 | latency.token_to_client.p50_ms | 0.19 |
| S2 headless-acpmux-10 | latency.token_to_client.p95_ms | 0.28 |
| S2 headless-acpmux-10 | start.ready_ms | 10.2 |
| S2 headless-acpmux-10 | stream.acpmux_cpu_s_per_session | 0.202 |
| S2 headless-acpmux-10 | stream.acpmux_cpu_us_per_chunk | 150 |
| S2 headless-acpmux-10 | stream.acpmux_disk_written_mb_per_session | 0 |
| S2 headless-acpmux-10 | stream.acpmux_syscalls_per_chunk | 2.21 |
| S2 headless-acpmux-10 | stream.chunks | 13498 |
| S2 headless-acpmux-10 | stream.client_mb | 0.29 |
| S2 headless-acpmux-10 | stream.sessions_ok | 10 |
| S2 headless-acpmux-10 | stream.text_mb | 0.293 |
| S2 headless-acpmux-10 | stream.wall_s | 77.92 |
| S2 headless-acpmux-100 | create.seconds | 0.65 |
| S2 headless-acpmux-100 | disk.acpmux_home_mb | 32.06 |
| S2 headless-acpmux-100 | latency.token_to_client.max_ms | 11.72 |
| S2 headless-acpmux-100 | latency.token_to_client.p50_ms | 0.22 |
| S2 headless-acpmux-100 | latency.token_to_client.p95_ms | 0.68 |
| S2 headless-acpmux-100 | start.ready_ms | 9.9 |
| S2 headless-acpmux-100 | stream.acpmux_cpu_s_per_session | 1.65 |
| S2 headless-acpmux-100 | stream.acpmux_cpu_us_per_chunk | 1,451 |
| S2 headless-acpmux-100 | stream.acpmux_disk_written_mb_per_session | 0 |
| S2 headless-acpmux-100 | stream.acpmux_syscalls_per_chunk | 2.21 |
| S2 headless-acpmux-100 | stream.chunks | 113490 |
| S2 headless-acpmux-100 | stream.client_mb | 2.49 |
| S2 headless-acpmux-100 | stream.sessions_ok | 100 |
| S2 headless-acpmux-100 | stream.text_mb | 2.46 |
| S2 headless-acpmux-100 | stream.wall_s | 77.94 |
| S3 headless-tui | create.seconds | 9.82 |
| S3 headless-tui | create.terminals | 1000 |
| S3 headless-tui | create.terminals_per_s | 102 |
| S3 headless-tui | disk.state_mb | 26.09 |
| S3 headless-tui | latency.keystroke_to_echo_headless.max_ms | 0.48 |
| S3 headless-tui | latency.keystroke_to_echo_headless.p50_ms | 0.1 |
| S3 headless-tui | latency.keystroke_to_echo_headless.p95_ms | 0.39 |
| S3 headless-tui | start.cold_identify_ms | 35.3 |
| S3 headless-tui | stop.leftover_terminal_hosts | 0 |
| S3 headless-tui | stop.shutdown_end_terminals_ms | 1,419 |
| S4 headless-tui | create.seconds | 10.32 |
| S4 headless-tui | create.terminals | 1000 |
| S4 headless-tui | create.terminals_per_s | 96.9 |
| S4 headless-tui | disk.state_mb | 36.66 |
| S4 headless-tui | latency.keystroke_to_echo_headless.max_ms | 0.52 |
| S4 headless-tui | latency.keystroke_to_echo_headless.p50_ms | 0.11 |
| S4 headless-tui | latency.keystroke_to_echo_headless.p95_ms | 0.38 |
| S4 headless-tui | restart.start_identify_ms | 7,303 |
| S4 headless-tui | restart.stop_keep_terminals_ms | 167 |
| S4 headless-tui | restart.to_topology_ms | 7,335 |
| S4 headless-tui | restart.workspaces_after | 200 |
| S4 headless-tui | start.cold_identify_ms | 36.1 |
| S4 headless-tui | stop.leftover_terminal_hosts | 0 |
| S4 headless-tui | stop.shutdown_end_terminals_ms | 1,306 |

