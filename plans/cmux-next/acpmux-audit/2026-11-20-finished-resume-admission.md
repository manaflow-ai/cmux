# Durable completion and outage recovery admission

Owner: finished-resume-admission (Codex), branch lane/finished-resume-admission-owned.

Completed work must not wake from messages, retries or daemon restart. Completion is stored in
session metadata separately from idle/closed process state; only the explicit reasoned wake
clears it. Fresh creates another session with the completion handoff in its draft. A finish
fences prepared turns and host startup, prevents a carried continuation, and retires the harness
after the current turn. Startup does not adopt finished hosts.

The fleet admission authority is explicitly enrolled using the existing authenticated peer
transport. Members pin its durable identity. Pause/resume from any member reaches the same
switch, and local authority retries use the same queue as remote members: four outstanding
retry reservations fleet-wide, with one-second spacing and shared priority order. No missing
peer or changed identity falls back locally. Reservation records survive authority restart;
disconnects and lost replies never free them on a timer. Uncertain work retains occupancy.
Normal messages release their reservation before waiting on reciprocal replies.

The existing stopgap must remain through deployed verification and enrollment of every intended
member. An unbound daemon is not fleet protected. No live configuration or stopgap was changed.
Recovery of uncertain reservations remains manual protocol reconciliation after proving the
member's work has stopped; there is no automatic lease expiry or unsafe force-release command.

Detector: `cmux-ci test -- cargo test --manifest-path cmux-tui/Cargo.toml -p acpmux --lib finished`.
It includes two real hubs connected through authenticated WebSocket peer transport and 100 fake
503 sessions: ten finished and ten paused goals must never resume; eighty recover under the
single cross-host admission bound. The single switch is exercised from the member. Additional
tests cover durable reservations across restart, no lease expiry, changed/missing authority,
priority, spacing, width, cancellation, finished metadata reload, fresh handoffs and RPC caller
ownership. Execution receipt pending; the prior local-only run failed compilation and is not
acceptance evidence.

The session lifecycle operations require a local proven caller or current terminal CLI, and an
agent finishes only itself. The fleet protocol branch requires authenticated peer-daemon proof;
Web, paired-device and unauthenticated peer origins do not gain fleet control.
