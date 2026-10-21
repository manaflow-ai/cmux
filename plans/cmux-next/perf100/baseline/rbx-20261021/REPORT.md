# perf100 run

Counter sources: cpu: /proc/<pid>/stat utime + stime; wakeups: voluntary_ctxt_switches summed over /proc/<pid>/task/*/status; rss: /proc/<pid>/status VmRSS; footprint: /proc/<pid>/smaps_rollup Pss (VmRSS when unreadable); threads: /proc/<pid>/status Threads; disk_written: /proc/<pid>/io write_bytes (storage-layer bytes, counted when dirtied; exact, unprivileged for own processes); disk_io_written: /proc/<pid>/io write_bytes; syscalls: /proc/<pid>/io syscr + syscw (I/O syscalls only); socket_bytes: not available per process without root on Linux; harness-owned connections only

`cmux` = app + tui + acpmux + browser + helpers. `agents` (replay stand-ins for agent CLIs), `workload` (the shells and programs in the terminals) and `harness` (this runner's CLI calls) are shown apart and are not in `cmux`. peak MB sums each process kind's peak.
### S0 headless-tui (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [7.42, 29.57, 30.01] -> [5.82, 23.65, 27.88]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 80.2 s

idle (60.02 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.01 | 0.017 | 0.18 | 237 | 84.8 | 84.8 | 194 | 0 | 0 | 14 |
| tui | 0.01 | 0.017 | 0.18 | 237 | 84.8 | 84.8 | 194 | 0 | 0 | 14 |
| workload | 0 | 0 | 0 | 53.5 | 15.2 | 15.2 | 13 | 0 | 0 | 13 |

per terminal: cmux_footprint_mb 6.52, cmux_rss_mb 18.26, cmux_threads 14.92, tui_footprint_mb 6.52, tui_rss_mb 18.26, tui_threads 14.92

| metric | value |
|---|---:|
| disk.state_mb | 5.33 |
| start.cold_identify_ms | 35.2 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 43.8 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk

### S1 headless-tui (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [5.82, 23.65, 27.88] -> [31.73, 26.8, 28.59]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 76.0 s

flood1 (38.6 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 234 | 606 | 947,143 | 211 | 187 | 187 | 54 | 0 | 0 | 3 |
| tui | 234 | 606 | 947,143 | 211 | 187 | 187 | 54 | 0 | 0 | 3 |
| workload | 38.32 | 99.28 | 658 | 6.5 | 1 | 1.5 | 2 | 0 | 0 | 2 |

flood10 (36.12 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 1,044 | 2,889 | 3,452,023 | 1,071 | 922 | 926 | 228 | 0 | 0 | 14 |
| tui | 1,044 | 2,889 | 3,452,023 | 1,071 | 922 | 926 | 228 | 0 | 0 | 14 |
| workload | 340 | 940 | 7,027 | 31.1 | 2.9 | 5.3 | 13 | 0 | 0 | 13 |

| metric | value |
|---|---:|
| disk.state_mb | 1,640 |
| flood1.client_socket_mb | 834 |
| flood1.cmux_cpu_s_per_100mb | 117 |
| flood1.cmux_disk_written_per_output_mb | 0 |
| flood1.finished | 1 |
| flood1.throughput_mb_s | 5.2 |
| flood1.wall_s | 38.59 |
| flood10.client_socket_mb | 2,368 |
| flood10.cmux_cpu_s_per_100mb | 52.17 |
| flood10.cmux_disk_written_per_output_mb | 0 |
| flood10.finished | 10 |
| flood10.throughput_mb_s | 55.8 |
| flood10.wall_s | 36.04 |
| start.cold_identify_ms | 34.8 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 1,079 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk

### S2 headless-acpmux-10 (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [52.75, 27.95, 28.13] -> [7.51, 18.58, 24.57]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 158.2 s

create (0.14 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0.07 | 49.78 | 12,112 | 108 | 39.3 | 39.3 | 235 | 0 | 0 | 11 |
| acpmux | 0.07 | 49.78 | 12,112 | 108 | 39.3 | 39.3 | 235 | 0 | 0 | 11 |
| agents | 0.08 | 56.9 | 213 | 152 | 58.3 | 58.3 | 10 | 0 | 0 | 10 |

idle (60.02 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0 | 108 | 39 | 39 | 227 | 0 | 0 | 11 |
| acpmux | 0 | 0 | 0 | 108 | 39 | 39 | 227 | 0 | 0 | 11 |
| agents | 0 | 0 | 0 | 152 | 58.5 | 58.5 | 10 | 0 | 0 | 10 |

per session: cmux_footprint_mb 3.9, cmux_rss_mb 10.82, cmux_threads 22.7, acpmux_footprint_mb 3.9, acpmux_rss_mb 10.82, acpmux_threads 22.7, agents_footprint_mb 5.85, agents_rss_mb 15.22, agents_threads 1

stream (77.94 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 2.02 | 2.59 | 1,180 | 122 | 53.2 | 53.2 | 231 | 0 | 0 | 11 |
| acpmux | 2.02 | 2.59 | 1,180 | 122 | 53.2 | 53.2 | 231 | 0 | 0 | 11 |
| agents | 0.41 | 0.526 | 0.38 | 161 | 65.7 | 65.7 | 10 | 0 | 0 | 10 |
| harness | 0.62 | 0.796 | 437 | 0 | 0 | 50.1 | 0 | 0 | 0 | 0 |

| metric | value |
|---|---:|
| create.seconds | 0.12 |
| disk.acpmux_home_mb | 3.95 |
| latency.token_to_client.max_ms | 0.33 |
| latency.token_to_client.p50_ms | 0.19 |
| latency.token_to_client.p95_ms | 0.28 |
| start.ready_ms | 10.2 |
| stream.acpmux_cpu_s_per_session | 0.202 |
| stream.acpmux_cpu_us_per_chunk | 150 |
| stream.acpmux_disk_written_mb_per_session | 0 |
| stream.acpmux_syscalls_per_chunk | 2.21 |
| stream.chunks | 13498 |
| stream.client_mb | 0.29 |
| stream.sessions_ok | 10 |
| stream.text_mb | 0.293 |
| stream.wall_s | 77.92 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk

### S2 headless-acpmux-100 (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [7.51, 18.58, 24.57] -> [10.01, 15.28, 22.34]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 158.9 s

create (0.71 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 1.02 | 144 | 56,202 | 805 | 124 | 124 | 505 | 0 | 0 | 101 |
| acpmux | 1.02 | 144 | 56,202 | 805 | 124 | 124 | 505 | 0 | 0 | 101 |
| agents | 0.99 | 140 | 424 | 1,522 | 543 | 543 | 100 | 0 | 0 | 100 |

idle (60.09 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0 | 804 | 123 | 123 | 497 | 0 | 0 | 101 |
| acpmux | 0 | 0 | 0 | 804 | 123 | 123 | 497 | 0 | 0 | 101 |
| agents | 0 | 0 | 0 | 1,522 | 543 | 543 | 100 | 0 | 0 | 100 |

per session: cmux_footprint_mb 1.23, cmux_rss_mb 8.04, cmux_threads 4.97, acpmux_footprint_mb 1.23, acpmux_rss_mb 8.04, acpmux_threads 4.97, agents_footprint_mb 5.43, agents_rss_mb 15.22, agents_threads 1

stream (78.04 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 165 | 211 | 64,577 | 845 | 164 | 164 | 501 | 0 | 0 | 101 |
| acpmux | 165 | 211 | 64,577 | 845 | 164 | 164 | 501 | 0 | 0 | 101 |
| agents | 2.82 | 3.61 | 4.37 | 1,601 | 604 | 604 | 100 | 0 | 0 | 100 |
| harness | 6.86 | 8.79 | 3,752 | 0 | 0 | 454 | 0 | 0 | 0 | 0 |

| metric | value |
|---|---:|
| create.seconds | 0.65 |
| disk.acpmux_home_mb | 32.06 |
| latency.token_to_client.max_ms | 11.72 |
| latency.token_to_client.p50_ms | 0.22 |
| latency.token_to_client.p95_ms | 0.68 |
| start.ready_ms | 9.9 |
| stream.acpmux_cpu_s_per_session | 1.65 |
| stream.acpmux_cpu_us_per_chunk | 1,451 |
| stream.acpmux_disk_written_mb_per_session | 0 |
| stream.acpmux_syscalls_per_chunk | 2.21 |
| stream.chunks | 113490 |
| stream.client_mb | 2.49 |
| stream.sessions_ok | 100 |
| stream.text_mb | 2.46 |
| stream.wall_s | 77.94 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk

### S3 headless-tui (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [31.73, 26.8, 28.59] -> [16.11, 23.06, 27.12]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 93.0 s

create (10.37 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 8.31 | 80.17 | 6,610 | 13,915 | 2,396 | 2,396 | 13025 | 0 | 0 | 1001 |
| tui | 8.31 | 80.17 | 6,610 | 13,915 | 2,396 | 2,396 | 13025 | 0 | 0 | 1001 |
| workload | 0 | 0 | 172 | 2,440 | 215 | 215 | 1000 | 0 | 0 | 1000 |

idle (61.11 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0.16 | 13,916 | 2,397 | 2,397 | 13025 | 0 | 0 | 1001 |
| tui | 0 | 0 | 0.16 | 13,916 | 2,397 | 2,397 | 13025 | 0 | 0 | 1001 |
| workload | 0 | 0 | 0 | 2,440 | 215 | 215 | 1000 | 0 | 0 | 1000 |

per terminal: cmux_footprint_mb 2.4, cmux_rss_mb 13.92, cmux_threads 13.03, tui_footprint_mb 2.4, tui_rss_mb 13.92, tui_threads 13.03

| metric | value |
|---|---:|
| create.seconds | 9.82 |
| create.terminals | 1000 |
| create.terminals_per_s | 102 |
| disk.state_mb | 26.09 |
| latency.keystroke_to_echo_headless.max_ms | 0.48 |
| latency.keystroke_to_echo_headless.p50_ms | 0.1 |
| latency.keystroke_to_echo_headless.p95_ms | 0.39 |
| start.cold_identify_ms | 35.3 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 1,419 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk

### S4 headless-tui (seed 1)

host `cmux-rust-builder-1` (class `rbx`, AMD EPYC 9B45, 192 cores, 354 GB, Linux-7.0.0-1011-gcp-x86_64-with-glibc2.39), load [16.11, 23.06, 27.12] -> [52.75, 27.95, 28.13]; build tag `rbx-release` sha `d8c03f5a3feb`; wall 101.5 s

create (10.87 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 8.8 | 80.97 | 6,276 | 14,173 | 2,660 | 2,660 | 13025 | 0 | 0 | 1001 |
| tui | 8.8 | 80.97 | 6,276 | 14,173 | 2,660 | 2,660 | 13025 | 0 | 0 | 1001 |
| workload | 0 | 0 | 163 | 2,441 | 215 | 215 | 1000 | 0 | 0 | 1000 |

idle (61.08 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 0 | 0 | 0.16 | 14,175 | 2,661 | 2,661 | 13025 | 0 | 0 | 1001 |
| tui | 0 | 0 | 0.16 | 14,175 | 2,661 | 2,661 | 13025 | 0 | 0 | 1001 |
| workload | 0 | 0 | 0 | 2,441 | 215 | 215 | 1000 | 0 | 0 | 1000 |

per terminal: cmux_footprint_mb 2.66, cmux_rss_mb 14.18, cmux_threads 13.03, tui_footprint_mb 2.66, tui_rss_mb 14.18, tui_threads 13.03

restart (8.22 s window)

| group | CPU s | CPU % | wakeups/s | RSS MB | footprint MB | peak MB | threads | written MB | written MB/min | procs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **cmux** | 9.04 | 110 | 8,570 | 2,033 | 2,007 | 2,662 | 3023 | 0 | 0 | 1 |
| tui | 9.04 | 110 | 8,570 | 2,033 | 2,007 | 2,662 | 3023 | 0 | 0 | 1 |
| workload | 0 | 0 | 0 | 0 | 0 | 215 | 0 | 0 | 0 | 0 |

| metric | value |
|---|---:|
| create.seconds | 10.32 |
| create.terminals | 1000 |
| create.terminals_per_s | 96.9 |
| disk.state_mb | 36.66 |
| latency.keystroke_to_echo_headless.max_ms | 0.52 |
| latency.keystroke_to_echo_headless.p50_ms | 0.11 |
| latency.keystroke_to_echo_headless.p95_ms | 0.38 |
| restart.start_identify_ms | 7,303 |
| restart.stop_keep_terminals_ms | 167 |
| restart.to_topology_ms | 7,335 |
| restart.workspaces_after | 200 |
| start.cold_identify_ms | 36.1 |
| stop.leftover_terminal_hosts | 0 |
| stop.shutdown_end_terminals_ms | 1,306 |

- UNVERIFIED: disk written is 0 in this run: the runner at 0ef3a1a15771 kept daemon state on rbx's tmpfs TMPDIR (/t), whose writes never reach storage; rbx-headless.sh now uses the ext4 root disk
