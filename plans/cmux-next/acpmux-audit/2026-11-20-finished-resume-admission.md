# Durable completion and outage recovery admission

Owner: finished-resume-admission (Codex), branch lane/finished-resume-admission-owned.

Completed work must not wake from messages, retries or daemon restart. Completion is stored in
session metadata separately from idle/closed process state; only the explicit reasoned wake
clears it. Fresh creates another session with the completion handoff in its draft. A finish
fences prepared turns and host startup, prevents a carried continuation, and retires the harness
after the current turn. Startup does not adopt finished hosts.

The per-daemon admission queue persists an operator pause and staggers outage recovery by
priority. Four retry turns may run concurrently; admissions are one second apart. Other agent
messages delayed by the pause release their slot before waiting for a reply. All final turn
admissions check the pause independently of the optional inbox setting. This is a local fleet
operator control, not a distributed broadcast or a machine-configuration change.

Detector: `cmux-ci test -- cargo test --manifest-path cmux-tui/Cargo.toml -p acpmux --lib finished`.
It includes 100 fake sessions that fail once with 503: ten finish during the outage, ninety
recover after release. Deterministic tests measure priority, spacing, width and cancellation;
other tests reopen the on-disk metadata, fence already-prepared turns, test fresh handoffs and
check local caller ownership through the server dispatcher. Execution receipt pending.

New lifecycle RPC: local proven caller or current terminal CLI only; an agent finishes only its own session. No peer
or Web allowlist addition. Local callers can deliberately reopen with a reason, or create a
fresh handoff session under the existing new-session permission inheritance rules.
