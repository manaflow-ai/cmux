# perf100 run

Counter sources: cpu: proc_pid_rusage(RUSAGE_INFO_V6) ri_user_time + ri_system_time; wakeups: proc_pid_rusage ri_interrupt_wkups (all wakeups from idle; includes ri_pkg_idle_wkups, which is 0 on Apple silicon and reported apart as pkg_idle_wakeups); rss: proc_pid_rusage ri_resident_size; footprint: proc_pid_rusage ri_phys_footprint (Activity Monitor Memory; footprint(1) total); threads: proc_pidinfo(PROC_PIDTASKINFO) pti_threadnum; disk_written: proc_pid_rusage ri_logical_writes (bytes written to files by the process, before the buffer cache; the most precise unprivileged per-process write counter on macOS); disk_io_written: proc_pid_rusage ri_diskio_byteswritten (I/O the process issued to storage); syscalls: proc_pidinfo(PROC_PIDTASKINFO) pti_syscalls_mach + pti_syscalls_unix; socket_bytes: bytes the harness's own clients receive (attach streams, acpmux send); macOS has no unprivileged per-process Unix-socket byte counter

`cmux` = app + tui + acpmux + browser + helpers. `agents` (replay stand-ins for agent CLIs), `workload` (the shells and programs in the terminals) and `harness` (this runner's CLI calls) are shown apart and are not in `cmux`. peak MB sums each process kind's peak.
### S0 app (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [19.12, 10.33, 11.46] -> [10.27, 13.77, 13.06]; build tag `p100base2` sha `0ef3a1a15771`; wall 152.0 s

idle (60.11 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 1.96 | 3.25 | 20.31 | 3,185 | 1,408 | 1,518 | 720 | 114 | 113 | 38 |
| app | 0.659 | 1.1 | 7.3 | 666 | 412 | 449 | 108 | 113 | 113 | 1 |
| tui | 0.003 | 0.005 | 0.13 | 400 | 182 | 188 | 333 | 0 | 0 | 16 |
| acpmux | 0.006 | 0.009 | 0 | 52.7 | 18.8 | 23.6 | 40 | 0 | 0 | 2 |
| browser | 1.29 | 2.14 | 12.88 | 2,041 | 779 | 867 | 230 | 0.434 | 0.433 | 16 |
| helpers | 0 | 0 | 0 | 26.4 | 15.7 | 18.7 | 9 | 0 | 0 | 3 |
| workload | 0 | 0 | 0 | 67.9 | 45.4 | 46.1 | 13 | 0 | 0 | 13 |

per terminal: tui_footprint_mb 14.01, tui_rss_mb 30.73, tui_threads 25.62

per tab: browser_footprint_mb 156, browser_rss_mb 408, browser_threads 46

| metric | value |
|---|---:|
| disk.stop.home_mb | 242 |
| latency.keystroke_to_glyph.max_ms | 11.98 |
| latency.keystroke_to_glyph.p50_ms | 1.66 |
| latency.keystroke_to_glyph.p95_ms | 5.12 |
| launch.socket_ms | 6,766 |
| setup.terminals | 10 |
| stop.quit_ms | 734 |

- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S0 headless-tui (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [8.38, 7.21, 19.22] -> [4.32, 6.28, 17.79]; build tag `p100base2` sha `0ef3a1a15771`; wall 82.4 s

idle (60.13 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.005 | 0.008 | 0.18 | 275 | 119 | 119 | 205 | 0 | 0 | 14 |
| tui | 0.005 | 0.008 | 0.18 | 275 | 119 | 119 | 205 | 0 | 0 | 14 |
| workload | 0 | 0 | 0 | 63.7 | 42.9 | 42.9 | 15 | 0 | 0 | 14 |

per terminal: cmux_footprint_mb 9.17, cmux_rss_mb 21.18, cmux_threads 15.77, tui_footprint_mb 9.17, tui_rss_mb 21.18, tui_threads 15.77

| metric | value |
|---|---:|
| disk.state_mb | 6.74 |
| start.cold_identify_ms | 200 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 347 |

- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S1 app (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [10.27, 13.77, 13.06] -> [27.78, 46.36, 41.72]; build tag `p100base2` sha `0ef3a1a15771`; wall 1219.6 s

flood1 (111.67 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 537 | 481 | 466 | 1,428 | 997 | 997 | 221 | 3,396 | 1,825 | 16 |
| app | 169 | 151 | 437 | 408 | 312 | 312 | 23 | 0 | 0 | 1 |
| tui | 365 | 327 | 0.86 | 529 | 389 | 400 | 111 | 3,396 | 1,825 | 4 |
| acpmux | 0.127 | 0.114 | 0 | 52.7 | 21.4 | 23.6 | 40 | 0 | 0 | 2 |
| browser | 0.014 | 0.012 | 1.67 | 412 | 258 | 258 | 38 | 0 | 0 | 6 |
| helpers | 2.68 | 2.4 | 26.68 | 25.9 | 16.6 | 18.2 | 9 | 0 | 0 | 3 |
| workload | 108 | 97.11 | 0.13 | 3.9 | 2.6 | 5 | 1 | 0 | 0 | 1 |

flood10 (987.99 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 5,579 | 565 | 2,166 | 3,445 | 2,467 | 5,751 | 409 | 69,910 | 4,246 | 27 |
| app | 504 | 51.06 | 2,143 | 1,476 | 1,335 | 4,293 | 65 | 1.33 | 0.081 | 1 |
| tui | 5,050 | 511 | 17.26 | 1,475 | 839 | 1,188 | 257 | 69,909 | 4,246 | 15 |
| acpmux | 1.52 | 0.154 | 0 | 52.8 | 19 | 21.5 | 40 | 0 | 0 | 2 |
| browser | 0.109 | 0.011 | 1.58 | 411 | 259 | 259 | 38 | 0 | 0 | 6 |
| helpers | 22.41 | 2.27 | 4.11 | 29.5 | 14.8 | 18.6 | 9 | 0 | 0 | 3 |
| workload | 5,711 | 578 | 0.04 | 47.2 | 31.7 | 56.4 | 12 | 0 | 0 | 12 |

after (30.11 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 199 | 662 | 17,428 | 3,470 | 2,490 | 2,491 | 413 | 3,364 | 6,703 | 27 |
| app | 64.63 | 215 | 17,422 | 1,477 | 1,335 | 1,335 | 67 | 0 | 0 | 1 |
| tui | 134 | 444 | 1.53 | 1,500 | 862 | 863 | 257 | 3,364 | 6,703 | 15 |
| acpmux | 0.073 | 0.242 | 0 | 52.8 | 19 | 19 | 40 | 0 | 0 | 2 |
| browser | 0.004 | 0.014 | 2.06 | 411 | 259 | 259 | 40 | 0 | 0 | 6 |
| helpers | 0.73 | 2.42 | 3.09 | 29.5 | 14.8 | 14.8 | 9 | 0 | 0 | 3 |
| workload | 0 | 0 | 0 | 47.2 | 31.7 | 31.7 | 12 | 0 | 0 | 12 |

| metric | value |
|---|---:|
| disk.stop.home_mb | 2,938 |
| flood1.cmux_cpu_s_per_100mb | 269 |
| flood1.cmux_disk_written_per_output_mb | 16.98 |
| flood1.finished | 1 |
| flood1.throughput_mb_s | 1.8 |
| flood1.wall_s | 112 |
| flood10.cmux_cpu_s_per_100mb | 279 |
| flood10.cmux_disk_written_per_output_mb | 34.96 |
| flood10.finished | 10 |
| flood10.throughput_mb_s | 2 |
| flood10.wall_s | 988 |
| launch.socket_ms | 1,267 |
| stop.quit_ms | 2,588 |

- note: S1: the terminals are tabs of one pane: one is visible, the others ingest output in the daemon only
- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S1 headless-tui (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [4.32, 6.28, 17.79] -> [28.23, 29.51, 26.4]; build tag `p100base2` sha `0ef3a1a15771`; wall 1110.9 s

flood1 (95.46 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 290 | 304 | 0.71 | 348 | 261 | 341 | 68 | 3,152 | 1,981 | 3 |
| tui | 290 | 304 | 0.71 | 348 | 261 | 341 | 68 | 3,152 | 1,981 | 3 |
| workload | 96.98 | 102 | 30.4 | 15.1 | 11 | 13.6 | 4 | 0.02 | 0.012 | 3 |

flood10 (1009.67 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 7,005 | 694 | 1.53 | 1,253 | 698 | 924 | 229 | 86,306 | 5,129 | 14 |
| tui | 7,005 | 694 | 1.53 | 1,253 | 698 | 924 | 229 | 86,306 | 5,129 | 14 |
| workload | 5,797 | 574 | 4.27 | 35.3 | 25.4 | 54.2 | 15 | 2.25 | 0.134 | 14 |

| metric | value |
|---|---:|
| disk.state_mb | 3,062 |
| flood1.client_socket_mb | 352 |
| flood1.cmux_cpu_s_per_100mb | 145 |
| flood1.cmux_disk_written_per_output_mb | 15.76 |
| flood1.finished | 1 |
| flood1.throughput_mb_s | 2.1 |
| flood1.wall_s | 95.38 |
| flood10.client_socket_mb | 4,590 |
| flood10.cmux_cpu_s_per_100mb | 350 |
| flood10.cmux_disk_written_per_output_mb | 43.15 |
| flood10.finished | 10 |
| flood10.throughput_mb_s | 2 |
| flood10.wall_s | 1,010 |
| start.cold_identify_ms | 143 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 4,335 |

- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S2 app (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [5.55, 3.78, 6.17] -> [5.83, 4.69, 6.04]; build tag `p100base4` sha `5e67ec46d167`; wall 205.4 s

idle (30.11 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.013 | 0.044 | 7.08 | 1,495 | 755 | 756 | 433 | 0 | 0 | 37 |
| app | 0.007 | 0.022 | 1.83 | 353 | 141 | 141 | 17 | 0 | 0 | 1 |
| tui | 0.001 | 0.005 | 0.13 | 342 | 168 | 168 | 245 | 0 | 0 | 12 |
| acpmux | 0 | 0 | 0 | 241 | 103 | 103 | 109 | 0 | 0 | 14 |
| browser | 0.004 | 0.014 | 2.86 | 513 | 314 | 315 | 41 | 0 | 0 | 6 |
| helpers | 0.001 | 0.003 | 2.26 | 46.3 | 28.9 | 28.9 | 21 | 0 | 0 | 4 |
| agents | 0 | 0 | 0 | 114 | 77.8 | 77.8 | 10 | 0 | 0 | 10 |
| workload | 0 | 0 | 0 | 37 | 24.4 | 24.4 | 10 | 0 | 0 | 10 |

per session: cmux_footprint_mb 75.51, cmux_rss_mb 149, cmux_threads 43.3, acpmux_footprint_mb 10.27, acpmux_rss_mb 24.12, acpmux_threads 10.9, browser_footprint_mb 31.41, browser_rss_mb 51.27, browser_threads 4.1, agents_footprint_mb 7.78, agents_rss_mb 11.35, agents_threads 1

stream (78.04 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 25.11 | 32.18 | 426 | 1,742 | 990 | 1,298 | 453 | 16.27 | 12.51 | 37 |
| app | 3.45 | 4.42 | 128 | 351 | 130 | 142 | 21 | 0.117 | 0.09 | 1 |
| tui | 0.091 | 0.116 | 0.18 | 342 | 158 | 168 | 245 | 6 | 4.61 | 12 |
| acpmux | 2.25 | 2.89 | 242 | 245 | 104 | 104 | 110 | 10.1 | 7.77 | 14 |
| browser | 19.31 | 24.75 | 53.07 | 758 | 568 | 866 | 56 | 0.055 | 0.042 | 6 |
| helpers | 0.002 | 0.003 | 2.32 | 46.3 | 28.9 | 28.9 | 21 | 0 | 0 | 4 |
| agents | 0.593 | 0.76 | 118 | 119 | 83.4 | 83.7 | 10 | 0 | 0 | 10 |
| workload | 0 | 0 | 0 | 37 | 24.4 | 24.4 | 10 | 0 | 0 | 10 |

| metric | value |
|---|---:|
| disk.stop.home_mb | 126 |
| latency.token_to_page.max_ms | 21.6 |
| latency.token_to_page.p50_ms | 12.41 |
| latency.token_to_page.p95_ms | 21.6 |
| launch.socket_ms | 3,535 |
| setup.agents | 10 |
| setup.seconds | 2.15 |
| stop.quit_ms | 653 |
| stream.cmux_cpu_s_per_session | 2.51 |
| stream.cmux_disk_written_mb_per_session | 1.63 |
| stream.sessions_ended | 10 |
| stream.wall_s | 77.95 |

- UNVERIFIED: token-to-screen pixels: S2 measures token-to-page (the agent pane's chat state); the paint after it is not measured

### S2 headless-acpmux-10 (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [13.55, 17.94, 21.88] -> [2.79, 11.37, 18.49]; build tag `p100base2` sha `0ef3a1a15771`; wall 159.4 s

create (0.74 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.254 | 34.47 | 224 | 164 | 63.3 | 63.3 | 55 | 7.19 | 586 | 11 |
| acpmux | 0.254 | 34.47 | 224 | 164 | 63.3 | 63.3 | 55 | 7.19 | 586 | 11 |
| agents | 0.725 | 98.45 | 0 | 144 | 109 | 109 | 10 | 10.75 | 876 | 10 |

idle (60.14 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0 | 163 | 63.2 | 63.2 | 50 | 0 | 0 | 11 |
| acpmux | 0 | 0 | 0 | 163 | 63.2 | 63.2 | 50 | 0 | 0 | 11 |
| agents | 0 | 0 | 0 | 144 | 109 | 109 | 10 | 0 | 0 | 10 |

per session: cmux_footprint_mb 6.32, cmux_rss_mb 16.33, cmux_threads 5, acpmux_footprint_mb 6.32, acpmux_rss_mb 16.33, acpmux_threads 5, agents_footprint_mb 10.86, agents_rss_mb 14.45, agents_threads 1

stream (78.11 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 4.18 | 5.36 | 345 | 180 | 77.8 | 78.6 | 52 | 7.24 | 5.56 | 11 |
| acpmux | 4.18 | 5.36 | 345 | 180 | 77.8 | 78.6 | 52 | 7.24 | 5.56 | 11 |
| agents | 1.14 | 1.46 | 169 | 152 | 116 | 116 | 10 | 0.504 | 0.387 | 10 |
| harness | 0.872 | 1.12 | 5.48 | 0 | 0 | 59.8 | 0 | 0 | 0 | 0 |

| metric | value |
|---|---:|
| create.seconds | 0.66 |
| disk.acpmux_home_mb | 4.26 |
| latency.token_to_client.max_ms | 2.12 |
| latency.token_to_client.p50_ms | 0.35 |
| latency.token_to_client.p95_ms | 0.57 |
| start.ready_ms | 37.1 |
| stream.acpmux_cpu_s_per_session | 0.418 |
| stream.acpmux_cpu_us_per_chunk | 310 |
| stream.acpmux_disk_written_mb_per_session | 0.724 |
| stream.acpmux_syscalls_per_chunk | 33.94 |
| stream.chunks | 13498 |
| stream.client_mb | 0.29 |
| stream.sessions_ok | 10 |
| stream.text_mb | 0.293 |
| stream.wall_s | 78 |

- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S2 headless-acpmux-100 (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [2.79, 11.37, 18.49] -> [13.8, 10.7, 16.87]; build tag `p100base2` sha `0ef3a1a15771`; wall 166.1 s

create (4.29 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 4.26 | 99.22 | 392 | 1,302 | 482 | 482 | 334 | 71.14 | 994 | 101 |
| acpmux | 4.26 | 99.22 | 392 | 1,302 | 482 | 482 | 334 | 71.14 | 994 | 101 |
| agents | 2.75 | 64.11 | 0 | 1,134 | 776 | 776 | 100 | 5.29 | 73.98 | 100 |

idle (60.13 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0 | 1,302 | 481 | 481 | 320 | 0 | 0 | 101 |
| acpmux | 0 | 0 | 0 | 1,302 | 481 | 481 | 320 | 0 | 0 | 101 |
| agents | 0 | 0 | 0 | 1,134 | 776 | 776 | 100 | 0 | 0 | 100 |

per session: cmux_footprint_mb 4.81, cmux_rss_mb 13.02, cmux_threads 3.2, acpmux_footprint_mb 4.81, acpmux_rss_mb 13.02, acpmux_threads 3.2, agents_footprint_mb 7.76, agents_rss_mb 11.34, agents_threads 1

stream (78.73 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 92.64 | 118 | 2,946 | 1,343 | 527 | 530 | 322 | 79.85 | 60.85 | 101 |
| acpmux | 92.64 | 118 | 2,946 | 1,343 | 527 | 530 | 322 | 79.85 | 60.85 | 101 |
| agents | 8.89 | 11.29 | 1,420 | 1,196 | 845 | 848 | 100 | 9.48 | 7.22 | 100 |
| harness | 6.92 | 8.79 | 45.32 | 0 | 0 | 598 | 0 | 0 | 0 | 0 |

| metric | value |
|---|---:|
| create.seconds | 4.18 |
| disk.acpmux_home_mb | 34.9 |
| latency.token_to_client.max_ms | 455 |
| latency.token_to_client.p50_ms | 0.78 |
| latency.token_to_client.p95_ms | 84.87 |
| start.ready_ms | 37.8 |
| stream.acpmux_cpu_s_per_session | 0.926 |
| stream.acpmux_cpu_us_per_chunk | 816 |
| stream.acpmux_disk_written_mb_per_session | 0.798 |
| stream.acpmux_syscalls_per_chunk | 86.2 |
| stream.chunks | 113490 |
| stream.client_mb | 2.49 |
| stream.sessions_ok | 100 |
| stream.text_mb | 2.46 |
| stream.wall_s | 78.64 |

- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.

### S3 app (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [3.91, 23.33, 32.74] -> [2.12, 12.91, 26.24]; build tag `p100base2` sha `0ef3a1a15771`; wall 205.4 s

create (57.28 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 75.66 | 132 | 148 | 4,394 | 2,226 | 2,226 | 2928 | 1,959 | 2,052 | 213 |
| app | 57.52 | 100 | 120 | 700 | 717 | 720 | 82 | 0.289 | 0.303 | 1 |
| tui | 17.76 | 31.01 | 16.69 | 3,200 | 1,214 | 1,214 | 2759 | 1,959 | 2,052 | 201 |
| acpmux | 0.108 | 0.189 | 0 | 52.4 | 23.3 | 23.3 | 40 | 0 | 0 | 2 |
| browser | 0.042 | 0.074 | 3.19 | 414 | 253 | 350 | 38 | 0 | 0 | 6 |
| helpers | 0.226 | 0.395 | 7.19 | 26.9 | 18.6 | 18.6 | 9 | 0 | 0 | 3 |
| workload | 1.89 | 3.3 | 13.53 | 733 | 482 | 482 | 199 | 0 | 0 | 199 |

idle (60.16 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.027 | 0.045 | 3.04 | 4,393 | 2,024 | 2,025 | 2924 | 0 | 0 | 213 |
| app | 0.011 | 0.018 | 1.3 | 699 | 515 | 516 | 78 | 0 | 0 | 1 |
| tui | 0.004 | 0.007 | 0.13 | 3,200 | 1,214 | 1,214 | 2759 | 0 | 0 | 201 |
| acpmux | 0 | 0 | 0 | 52.4 | 23.3 | 23.3 | 40 | 0 | 0 | 2 |
| browser | 0.012 | 0.02 | 1.61 | 414 | 253 | 254 | 38 | 0 | 0 | 6 |
| helpers | 0 | 0 | 0 | 26.9 | 18.6 | 18.6 | 9 | 0 | 0 | 3 |
| workload | 0 | 0 | 0 | 733 | 482 | 482 | 199 | 0 | 0 | 199 |

per terminal: cmux_footprint_mb 10.12, cmux_rss_mb 21.97, cmux_threads 14.62, tui_footprint_mb 6.07, tui_rss_mb 16, tui_threads 13.79, app_footprint_mb 2.58, app_rss_mb 3.5, app_threads 0.39

per workspace: cmux_footprint_mb 10.12, cmux_rss_mb 21.97, cmux_threads 14.62, app_footprint_mb 2.58, app_rss_mb 3.5, app_threads 0.39

| metric | value |
|---|---:|
| create.seconds | 57.18 |
| create.terminals | 200 |
| create.workspaces | 200 |
| disk.stop.home_mb | 237 |
| latency.keystroke_to_glyph.max_ms | 31.72 |
| latency.keystroke_to_glyph.p50_ms | 9.36 |
| latency.keystroke_to_glyph.p95_ms | 19.44 |
| launch.socket_ms | 1,248 |
| stop.quit_ms | 4,535 |

- note: S3: 200 x 5 terminals exceed the PTYs this job may take (300); ran 200 x 1
- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.
- UNVERIFIED: S3 at 1000 terminals in the app: PTY cap 300 on this host

### S3 headless-tui (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [28.23, 29.51, 26.4] -> [6.92, 21.64, 23.67]; build tag `p100base2` sha `0ef3a1a15771`; wall 100.0 s

create (16.0 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 7.88 | 49.27 | 71.37 | 2,942 | 1,044 | 1,044 | 2636 | 486 | 1,823 | 201 |
| tui | 7.88 | 49.27 | 71.37 | 2,942 | 1,044 | 1,044 | 2636 | 486 | 1,823 | 201 |
| workload | 3.21 | 20.06 | 63.44 | 748 | 493 | 493 | 202 | 0.051 | 0.19 | 201 |

idle (60.16 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.002 | 0.003 | 0.17 | 2,942 | 1,044 | 1,044 | 2636 | 0 | 0 | 201 |
| tui | 0.002 | 0.003 | 0.17 | 2,942 | 1,044 | 1,044 | 2636 | 0 | 0 | 201 |
| workload | 0 | 0 | 0 | 749 | 493 | 493 | 202 | 0 | 0 | 201 |

per terminal: cmux_footprint_mb 5.22, cmux_rss_mb 14.71, cmux_threads 13.18, tui_footprint_mb 5.22, tui_rss_mb 14.71, tui_threads 13.18

| metric | value |
|---|---:|
| create.seconds | 15.9 |
| create.terminals | 200 |
| create.terminals_per_s | 12.6 |
| disk.state_mb | 12.84 |
| latency.keystroke_to_echo_headless.max_ms | 0.26 |
| latency.keystroke_to_echo_headless.p50_ms | 0.13 |
| latency.keystroke_to_echo_headless.p95_ms | 0.23 |
| start.cold_identify_ms | 154 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 3,650 |

- note: S3: 1000 terminals exceed the free PTYs (300); ran 200 x 1
- note: wakeups_per_s relabelled after the run: the runner at 0ef3a1a15771 recorded ri_interrupt_wkups as interrupt_wakeups_per_s and ri_pkg_idle_wkups (0 on Apple silicon) as wakeups_per_s; this file moves interrupt wakeups to wakeups_per_s, as the landed runner records it. No value was changed.
- UNVERIFIED: S3 at 1000 terminals: this host's PTY limit allows 300

### S4 app (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [8.61, 6.12, 6.29] -> [7.67, 9.64, 7.99]; build tag `p100base5` sha `db68ce4fa021`; wall 202.9 s

create (46.55 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 59.16 | 127 | 239 | 4,288 | 2,172 | 2,172 | 2931 | 1,931 | 2,489 | 213 |
| app | 40.5 | 87 | 207 | 623 | 679 | 679 | 83 | 0 | 0 | 1 |
| tui | 18.26 | 39.22 | 16.65 | 3,176 | 1,200 | 1,200 | 2759 | 1,931 | 2,489 | 201 |
| acpmux | 0.134 | 0.288 | 0 | 52.8 | 19.9 | 19.9 | 40 | 0 | 0 | 2 |
| browser | 0.045 | 0.097 | 6.06 | 409 | 257 | 354 | 40 | 0 | 0 | 6 |
| helpers | 0.23 | 0.495 | 8.77 | 27.3 | 16.7 | 17.3 | 9 | 0 | 0 | 3 |
| workload | 2.07 | 4.45 | 15.19 | 735 | 484 | 484 | 199 | 0 | 0 | 199 |

idle (60.15 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.024 | 0.04 | 3.32 | 4,288 | 1,971 | 1,972 | 2923 | 0 | 0 | 213 |
| app | 0.01 | 0.017 | 1.43 | 623 | 478 | 478 | 79 | 0 | 0 | 1 |
| tui | 0.004 | 0.006 | 0.13 | 3,176 | 1,200 | 1,200 | 2759 | 0 | 0 | 201 |
| acpmux | 0 | 0 | 0 | 52.8 | 19.9 | 19.9 | 40 | 0 | 0 | 2 |
| browser | 0.01 | 0.017 | 1.76 | 409 | 257 | 257 | 36 | 0 | 0 | 6 |
| helpers | 0 | 0 | 0 | 27.3 | 16.7 | 16.7 | 9 | 0 | 0 | 3 |
| workload | 0 | 0 | 0 | 735 | 484 | 484 | 199 | 0 | 0 | 199 |

per terminal: cmux_footprint_mb 9.86, cmux_rss_mb 21.44, cmux_threads 14.62, tui_footprint_mb 6, tui_rss_mb 15.88, tui_threads 13.79, app_footprint_mb 2.39, app_rss_mb 3.11, app_threads 0.4

per workspace: cmux_footprint_mb 9.86, cmux_rss_mb 21.44, cmux_threads 14.62, app_footprint_mb 2.39, app_rss_mb 3.11, app_threads 0.4

restart (2.93 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 2.8 | 95.55 | 218 | 4,015 | 2,036 | 2,055 | 2852 | 1.46 | 29.83 | 213 |
| app | 1.66 | 56.73 | 165 | 342 | 276 | 478 | 33 | 0.328 | 6.71 | 1 |
| tui | 0.105 | 3.57 | 0.68 | 3,163 | 1,205 | 1,205 | 2684 | 0.212 | 4.34 | 201 |
| acpmux | 0.049 | 1.65 | 2.73 | 52.7 | 23.4 | 23.4 | 45 | 0.5 | 10.23 | 2 |
| browser | 0.984 | 33.54 | 49.78 | 429 | 514 | 536 | 81 | 0.418 | 8.55 | 6 |
| helpers | 0.002 | 0.052 | 0 | 28.3 | 17.7 | 17.7 | 9 | 0 | 0 | 3 |
| workload | 0 | 0.005 | 0 | 733 | 487 | 487 | 199 | 0 | 0 | 199 |

| metric | value |
|---|---:|
| cold.first_window_frame_committed_ms | 2,746 |
| cold.launch_to_interactive_ms | 4,233 |
| cold.quit_end_sessions_ms | 190 |
| cold.socket_ms | 3,802 |
| create.seconds | 46.44 |
| create.terminals | 200 |
| create.workspaces | 200 |
| disk.stop.home_mb | 237 |
| latency.launch_to_interactive.cold_ms | 4,233 |
| latency.launch_to_interactive.restart_ms | 2,286 |
| restart.launch_to_all_workspaces_ms | 2,297 |
| restart.launch_to_interactive_ms | 2,286 |
| restart.quit_keep_sessions_ms | 485 |
| restart.terminals | 200 |
| stop.quit_ms | 0.2 |

- note: S4 cold: the launch window had no terminal tab; launch-to-interactive includes a New Tab
- note: S3: 200 x 5 terminals exceed the PTYs this job may take (300); ran 200 x 1
- UNVERIFIED: S3 at 1000 terminals in the app: PTY cap 300 on this host
- UNVERIFIED: S4 restart-to-update: quit with sessions kept and launch of the same build; the Sparkle install and UpdateWindowHandoff path are not exercised

### S4 headless-tui (seed 1)

host `cmuxs-MacBook-Pro-2` (class `cmux-lawrence-2`, Apple M5 Pro, 15 cores, 48 GB, 27.0.1), load [22.81, 8.0, 6.87] -> [18.98, 9.02, 7.29]; build tag `p100base4` sha `5e67ec46d167`; wall 109.0 s

create (16.59 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 8.44 | 50.86 | 62.98 | 2,939 | 1,041 | 1,041 | 2636 | 477 | 1,725 | 201 |
| tui | 8.44 | 50.86 | 62.98 | 2,939 | 1,041 | 1,041 | 2636 | 477 | 1,725 | 201 |
| workload | 3.29 | 19.81 | 53.22 | 748 | 493 | 493 | 202 | 0.051 | 0.184 | 201 |

idle (60.16 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.002 | 0.003 | 0.17 | 2,940 | 1,043 | 1,043 | 2636 | 0 | 0 | 201 |
| tui | 0.002 | 0.003 | 0.17 | 2,940 | 1,043 | 1,043 | 2636 | 0 | 0 | 201 |
| workload | 0 | 0 | 0 | 749 | 494 | 494 | 202 | 0 | 0 | 201 |

per terminal: cmux_footprint_mb 5.21, cmux_rss_mb 14.7, cmux_threads 13.18, tui_footprint_mb 5.21, tui_rss_mb 14.7, tui_threads 13.18

restart (7.31 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 3.6 | 49.24 | 31.48 | 3,092 | 1,167 | 1,167 | 2625 | 145 | 1,191 | 201 |
| tui | 3.6 | 49.24 | 31.48 | 3,092 | 1,167 | 1,167 | 2625 | 145 | 1,191 | 201 |
| workload | 0.004 | 0.054 | 0 | 741 | 486 | 494 | 202 | 0 | 0 | 201 |

| metric | value |
|---|---:|
| create.seconds | 16.5 |
| create.terminals | 200 |
| create.terminals_per_s | 12.1 |
| disk.state_mb | 16.84 |
| latency.keystroke_to_echo_headless.max_ms | 0.22 |
| latency.keystroke_to_echo_headless.p50_ms | 0.12 |
| latency.keystroke_to_echo_headless.p95_ms | 0.17 |
| restart.start_identify_ms | 5,731 |
| restart.stop_keep_terminals_ms | 89.2 |
| restart.to_topology_ms | 7,100 |
| restart.workspaces_after | 200 |
| start.cold_identify_ms | 170 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 4,647 |

- note: S3: 1000 terminals exceed the free PTYs (300); ran 200 x 1
- UNVERIFIED: S3 at 1000 terminals: this host's PTY limit allows 300
