# Incident header

- Symptom: macOS main-process hang / beachball with high retained memory.
- User impact: cmux was unresponsive for 215.92 seconds during the report window.
- Source: private local macOS hang/stackshot report plus the user-supplied workload hypothesis. The raw report remains local and is not copied into this evidence directory.
- Target surface: macOS, Apple silicon.
- Build/version/tag: cmux 0.64.17 build 97 (`com.cmuxterm.app`) on macOS 26.5 build 25F71.
- Event window: 2026-07-15 10:50:30.847 through 10:54:06.767 -0700.
- Process scale: 3563.51 MB footprint and 195 threads.
- Main-thread signature: all 11 samples include `GraphHost.flushTransactions`; 10 include `GraphHost.runTransaction`; 8 include `AG::Subgraph::update`. Sampled descendants include `LazySubviewPlacements`, `LazyStack`, and `ForEachList` layout/update work.
- Repro workload: bounded approximation of many fleet-backed subagents using many isolated workspaces/surfaces, process-title/runtime/status churn, hooks/feed/socket traffic, and repeated create/terminate lifecycle operations.
- Expected bad behavior: sustained main-thread layout/transaction work, high CPU, unbounded memory/thread/workspace growth, socket failure, or a live hang.
- Workload hypothesis: “many fleet-backed subagents” is unconfirmed context, not established causality.

## Primary classification

Hang / UI unresponsiveness with memory-growth and scale-risk signals. The report proves the SwiftUI lazy-layout transaction signature in the stable build, but by itself does not identify the owning cmux view or prove that fleet/subagent activity caused it.

## Privacy boundary

Only the facts above are approved for public issue evidence. Do not publish the raw RTF, full process inventory, paths, identifiers unrelated to cmux, or other system details.
