# Reply Sources provenance

Leo-Ask-Trace: ask-bdba7066a6

`hub/turn_sources.rs` records successful typed Read/WebFetch calls in the current agent turn. It runs after child/replay/mute filtering in the existing tap, rejects non-tool updates before taking a lock, and emits one `turn_sources` event bound to the final reply segment. Collection retains at most 32 pending calls, 64 sources and 128 terminal ids, with bounded strings. It scans neither transcript history nor tool output; reply rendering does one exact row lookup.

No timer, network request, new filesystem store or idle work. Source events use the existing log/replay path. The UI mounts its source list only when opened. Tests detect child attribution, pre-prompt reads, failure, reset, duplicate targets, state bounds and late-event cross-turn leakage. Sources describes access provenance, not sentence-level support. Hosted wiki backlink indexing remains a provider integration using explicit source-use identities and existing access control.
