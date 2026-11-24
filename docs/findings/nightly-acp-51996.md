# NIGHTLY acp daemon CPU on cosmic-gray

**Owner** — gcp-agent-lane-2/acpmux-owner. **Observed** — November 23, 2026, 21:18–21:20 PST, PID 51996, launched 20:32:12 PST.

The daemon consumed 7.33 CPU-seconds in 6.523 seconds around a five-second sample (112.4% of one core). A second sample with per-thread accounting measured 5.63 CPU-seconds in 6.090 seconds (92.5%). All 29 Tokio workers combined used 5.220 seconds, about 93% of the second window’s process CPU. On the same counters, all seven record-watch threads used 0.0075 seconds, both FSEvents loops 0.000375 seconds, and the settings watcher zero.

## Hot stacks

1. Background-task lists. `server::chats::route → Hub::bg_list_as → Hub::bg_records → bg_run::read_record → std::fs::read → open/read`. A second branch under the same request is `bg_list_as → bg_view → bg_run::read_output → ReadDir::next → readdir_r → __getdirentries64`. Each list opens and reads the directory’s task JSON records before filtering by scope. For each returned task it enumerates the same directory again to discover output segments and fetch its tail. Listing cost therefore grows with both task count and directory size. [Listing and record scan](https://github.com/manaflow-ai/cmux/blob/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/cmux-tui/crates/acpmux/src/hub/bg_tasks.rs#L366) · [Segment directory scan](https://github.com/manaflow-ai/cmux/blob/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/cmux-tui/crates/acpmux/src/bg_run.rs#L161)
2. Prompt history lookups. `Hub::prompt_with → logged_inbox_answer → scan_kinds_keyed → LocalStore::read_kind_index → kind_index::fnv_on`. A second worker reaches the same checksum through `logged_prompt_past_inbox → logged_prompt_records`. Each index read loads the segment’s sidecar and hashes its covered line bytes to validate it. This repeats even when the lookup asks for one prompt ID. [Index read and validation](https://github.com/manaflow-ai/cmux/blob/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/cmux-tui/crates/acpmux/src/store/kind_index.rs#L646) · [Inbox lookup](https://github.com/manaflow-ai/cmux/blob/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/cmux-tui/crates/acpmux/src/hub/inbox.rs#L2435) · [Prompt-ledger lookup](https://github.com/manaflow-ai/cmux/blob/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/cmux-tui/crates/acpmux/src/hub/prompt_ledger.rs#L470)

## Five busiest threads

CPU time is the change in the kernel’s user-plus-system counters across the paired capture. The leaf counts are exclusive observations from 1,760 wall-clock samples per thread. A syscall leaf can include blocked time. Each row lists the leading leaves after omitting scheduler waits. All five threads were named tokio-rt-worker.

| Thread ID | CPU seconds | Leading leaves (exclusive samples) |
|---|---:|---|
| 2029502409 | 1.436 | fnv_on 301, __open 117, read 108 |
| 2029502216 | 0.942 | __open 503, read 385, __getdirentries64 326 |
| 2029495889 | 0.844 | read 542, __open 539, __getdirentries64 332 |
| 2029494962 | 0.642 | fnv_on 123, __open 37, read 36 |
| 2029502732 | 0.454 | __open 433, read 244, __getdirentries64 146 |

The paired counters cover 62 surviving threads, accounting for 5.561 of 5.63 process CPU-seconds. All Tokio, record-watch, settings-watch and FSEvents threads in that sample were covered. Both hot paths also appear in the original 21:17 capture and the independent 21:18 capture. The profiles identify request handlers. They cannot identify the requesting client or its call frequency.

## Release identity and artifacts

NIGHTLY build 4532355634201, commit f3b932edb97980bb6f0f259b1ed6d06b92e9fea5, arm64 CLI UUID 4C4C44E3-5555-3144-A16F-F108E1E0FC33, load address 0x104b38000. The installed CLI and the unstripped release producer have byte-identical executable text (73,325,296 bytes, SHA-256 981c303a39f5e579a765f79aed041922c04edaa31bc5aa19b091881eb2cab3b9). The release producer was packaged into a matching dSYM with dsymutil. It retains function names. Source lines above come from inspection of the pinned commit. Linker-folded routines appear as <deduplicated_symbol> in the full stacks. [CLI manifest](https://files.cmux.com/cmux-tui/f3b932edb97980bb6f0f259b1ed6d06b92e9fea5/manifest.json) · [Producer run](https://github.com/manaflow-ai/cmux/actions/runs/45319543092) · [NIGHTLY run](https://github.com/manaflow-ai/cmux/actions/runs/45323556342)

Evidence on cosmic-gray is in /private/tmp/nightly-acp-51996.MuDoSf. The attached archive includes the paired symbolicated sample, the original sample after symbolication, both CPU windows and the per-thread rankings.

**Owner action** — measure these two handlers separately with a populated background-task directory and a long-lived session. Count directory enumerations per list, file opens per list, and sidecar bytes reread and rehashed per prompt. Use the same workload and PID-level CPU accounting to verify the fix. Preserve spool rotation and index integrity semantics.
