# Stalled Goal Review experiment

Source: [Shadow Leo RFD](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/rfd/0015-shadow-leo.md).

The first slice is NEXT-only and opt-in through Settings → Labs → Stalled Goal Review (`labs.shadowReview`, default false). Enabling it reviews live local sessions immediately after startup settles, then every 15 minutes. Explicit blocked/stalled goals produce a durable `mux.shadow_review` journal record containing the snapshot hash, target, proposed brief, stop condition, timestamp, and numeric evidence. It sends no messages and calls no model.

The agent chat displays the existing muted notice style: “Stalled goal review recorded (no message sent): {goal}”. There are no new controls, motion, colors, or panels. `ShadowReview.gallery.tsx` covers short, long, and Unicode objectives. Both history and live delivery use the same notice, including the v2 book translator.

Busy, queued, permission-waiting, protected, closed, intentionally paused, completed, and quota-limited sessions are excluded. Identical snapshots are suppressed across ordinary restarts; changed snapshots are limited to one per hour per session. One metadata receipt bounds state independently of transcript size. Journal append and metadata persistence are separate: a crash between them may repeat a log note, never an intervention. Disabled mode has no timer and uses the existing settings-change watcher.

The RFD baseline at 2026-11-19 10:06Z was author-wait p50 18h / p90 134h, 983 items over SLO, and 123 dead lanes holding work. This slice does not measure or claim a fleet improvement. It provides local evidence for a later replay; fleet-wide six-signal review, cycles.jsonl aggregation, an auditor, and sending remain outside this slice.
