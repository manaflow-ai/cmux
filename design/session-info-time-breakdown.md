# Session Info time breakdown

A quiet stacked bar and six aligned category totals explain active chat wall time.
It shares Session Info's typography, spacing and muted text colors. The default is
stacked; the gallery also presents lanes and totals. Stacked keeps the compact
panel readable while preserving chronological turn links.

## State and interaction

Absent journal data hides the section. Available data renders without motion.
An active interval updates on existing session notifications; no timer runs while
idle. A page contains at most 24 of the 512 recent spans. Previous/next controls
retain the same row height. Hover or keyboard focus identifies category, duration,
turn and measured whole-turn tokens; activation loads and reveals that turn through
the existing transcript history loader. Lifetime totals survive span eviction.
The native Session Info bridge provides totals and accessible turn actions as its
existing row-based fallback.

## Measurement contract

Wall time starts with a prompt and stops at the turn's end marker. Idle time between
unrelated prompts is excluded. Pending approvals are person time; thought chunks
mark thinking; read/search and edit tools classify their own intervals. Other tools
are commands; fetch tools and model response intervals are network/model time.
Concurrent tools share one wall-time interval, assigned deterministically to the
lowest tool id, so elapsed time is never double counted. Nested subagent events do
not alter their parent's phase. This is an event-based breakdown, not a CPU profile.

The journal measures tokens per turn, not per activity. Whole-turn token counts
appear in tooltips and known-turn totals. Category token attribution remains
unavailable. Missing or ambiguous legacy usage makes the total explicitly partial.

## Verification

The Rust fixture uses real JSON-RPC update envelopes, overlapping and reissued
approvals, a withdrawn request, a subagent event, and flat durable token counters.
Reducer tests cover bounded retention, late results, stopped turns and duplicate
records. Web tests cover malformed input and bounded paging; gallery interaction
checks turn activation and narrow layouts across all three variants.
