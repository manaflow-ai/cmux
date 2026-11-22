# No next-prompt suggestions for agent turns, and hosts that move onto the new build

From the sr2 token-waste audit (2026-11-21). The sr2 gateway saw about 1,000 Claude Code
next-prompt suggestions an hour (about $0.10 each) for turns that no person reads. Five
commits on feat-cmux-next:

- 40814c20..bc6ef4c8: `HostRecord::host_level` (`agent_host::HOST_LEVEL`). An adopted host
  below the level, on another build, moves at its chat's first 10 s idle point
  (`hub/host_level.rs`, `MOVE_AFTER`) under every hibernation gate. Each chat moves at most once
  per daemon run. Nothing moves while idle hibernation is off.
- d82059e9..12854f63: a per-turn suggestion pause for old hosts. It did nothing: Claude Code
  2.1.329 honours `set_prompt_suggestions_paused` only under its server-side flag
  `tengu_chomp_sable`, which is off by default, and it reads `promptSuggestions` only at
  `initialize`. The next commit removes it.
- c3ddff9b..3e09fb44: `HOST_LEVEL` 2. A start for no person (another agent's message, an
  acpmux notice, a chat an agent or a script created) sends `initialize` with
  `_meta.acpmux.noPromptSuggestions` (`Hub::start_params`, `Session::start_for`), and the
  translator asks Claude Code for none (`claude_stdio/outbound.rs`).
- f3a34999..46829ab7: a chat with no creator (an adopt, a failover target) counts as the
  person's only when `NewRequest::person` (`host_level::start_for_creator`).
- This change: `SessionMeta::start_level`, the level at which a daemon started each host
  incarnation (`Hub::note_start_level`). The update installs the new binary up to an hour
  (`RESTART_WINDOW_SECS`) before the daemon restarts on it. A host started meanwhile runs the
  new build, but the old daemon asked it for suggestions, so it never moved. A host with no
  start at this level, in a chat that is no person's, now moves at idle. A pooled agent that a
  person's chat takes keeps its level; one that another chat takes moves. On
  gcp-agent-lane-11, every start until its daemon restarted at 20:37Z asked for suggestions.

Effect: fleet suggestions went from about 1,017 an hour (18:45-19:55Z) to 733 (20:05-21:05Z).
Recaps went from 198 to 18 an hour.

Costs: each chat that moves restarts once, which costs one cache re-read. A process that a
person started keeps suggestions for its whole life, agent turns included.
