# Notice to PL-acpmux: Claude Code's own cross-session messaging in acpmux agents (2026-11-10)

Owner W7-A (bench round 6, A5 3 -> 1). `hub/native_messaging.rs` has the design and the measured
facts (Claude Code 2.1.322 through `sr2 claude`, fleet Mac).

- Every Claude Code the daemon starts gets `CLAUDE_CODE_HARBOR_KITE=0`: an agent
  (`agent/command.rs`, in the Claude block beside `CLAUDE_CODE_ENABLE_TASKS`) and the model probe
  (`live_models/mod.rs`, which starts Claude Code on its own path; CI found its peer entries). A
  profile or login value wins. Cost: one env entry per spawn; no new I/O. Effect: Claude Code
  binds no inbox socket, writes no peer address and has no `ListAgents`.
- The PreToolUse gate (`hub/policy_gate.rs` `answer_tool_gate`) checks a `SendMessage` first:
  one lock of the session map and an exact name or id compare per session, only for
  `SendMessage` calls (no other tool pays it). A refusal is logged as `permission_auto` with
  `reason: native_message`.
- `system/peer_message_hold` becomes the `peer_message_hold` session update; the hub keeps the
  holds in memory per session (at most 100) and the summary carries `heldMessages` (an empty
  array when none). A change bumps `state_seq` and marks the row changed, as a profile respawn
  does. `acpmux pending` reads them from the one sessions list it already reads. In memory only
  (accepted by the lead): a daemon restart forgets the holds; the docs and `pending` help say so.
- Risk: `CLAUDE_CODE_HARBOR_KITE` is an undocumented Claude Code switch (found in the 2.1.322
  binary). If a later Claude Code renames or drops it: `ListAgents` lists every Claude Code of
  the machine again (acpmux agents of other daemons too), and other sessions can message an
  acpmux agent, which may hold the message. What still holds: the gate refuses every
  `SendMessage` to an acpmux session or cross-session address with the acpmux command
  (`w7a_the_gate_refuses_a_native_send_when_the_switch_has_no_effect`), and a hold shows in
  `pending`. Only the cross-daemon peer list comes back.
