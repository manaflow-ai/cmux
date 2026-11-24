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

## 2026-11-22: a script's chat took the person's warm Claude Code

After 0a4bf688 reached the lanes, fleet suggestions were about 102 an hour (03:23-04:23Z). The
largest source was one team gateway (`cmux inference gateway` on gcp-agent-lane-13). It serves
the Freestyle machines fs-agent-lane-1 and fs-agent-lane-2, which both ran 6b8c79ba6. In 90
minutes it sent 30 suggestions in 430 calls. The gateway passes no `x-claude-code-session-id`
(`cli/inference_gateway.rs` `PASS_HEADERS`), so sr2 shows these calls as `fallback:` ids.

Cause: `session/new` took a pooled Claude Code for any chat with a plain shape, also for a chat
that a script made. The pool starts each agent for the person, so its `initialize` asks for
suggestions. Claude Code reads that once per process. On the two machines, 81 chats that
scripts made had taken a pooled agent, and each one asked for suggestions. The idle move from
0a4bf688 did not catch them: these chats nearly always have a background command running, so
they never reach the idle point.

Fix: a Claude Code chat takes a pooled agent only when the person made it
(`host_level::made_for_a_person`, `lifecycle.rs` `shaped`). Other chats start cold and send
`_meta.acpmux.noPromptSuggestions`. Other harnesses are unchanged. Cost: a script's Claude
Code chat starts cold (about one agent start), and its shape gets no spare.
