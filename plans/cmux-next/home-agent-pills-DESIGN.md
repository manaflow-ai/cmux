# Home: Chief subagents as pills, opened in a right pane

User 2026-11-03 (msgs 19960 and its clarification, ChatGPT reference shots). Status: design; the
playground variants come next, then the default ships.

## What the user sees

In a Chief's Home chat (the person's messages purple, the Chief's gray), every subagent the Chief
starts or talks to is a **pill** in the transcript, at the place of the turn that touched it, under
that turn's timestamp:

```
                    Today 10:42 AM
  ( ✓  Fix caret blink in Home      •  › )
  ( ◌  Agent session teleport          › )
```

- Status icon: a spinner while it works, a check when it reported, a cross when it failed or stopped
  without a report, a pause when it waits for an answer.
- Title: the spawn task's `Title:` line (2-5 words); its id (`a963`) when there is none.
- Unread dot: the agent reported (or wrote) after the person last opened it.
- `›`: it opens.

The pills replace the "Agent messages (N)" fold and the "Disconnected (N)" notes line. The Chief's own
words stay bubbles. A turn that touches one agent several times shows one pill (its newest state).

**Click a pill**: the agent's chat opens in a **right pane** of the Home page, as a tab in that
pane's tab strip, one tab per opened agent (a second click on the same pill selects its tab). The pane:

1. Header: title, status, where it runs (this Mac, a mini, the cloud), **Go to workspace** (opens the
   agent's own workspace, making it visible first if the agent ran hidden), close.
2. A **"Sent via Chief"** bubble with the task (first lines, **Show more**).
3. **"Worked for 5m 35s ›"** (the run's steps fold here; the arrow opens them).
4. The agent's replies.
5. A **composer**. The person and the Chief both write to the agent here. Every message is labelled
   with its sender ("You", "Chief"). What the person sends reaches the Chief too, as a line in its
   log (`[a963] the user wrote: …`), so the Chief never loses track of instructions it did not give.
   There is no "Chief is managing this / Take over" bar.

Cmd-click a pill: go straight to the agent's workspace. Right-click: Open, Go to Workspace, Copy Link,
Stop.

## Data

One value per (Chief conversation, agent) — `HomeAgentPeer` in CmuxHomeCore:

| Field | Source |
|---|---|
| `id` (`a963`) | the Chief's spawn registry |
| `title` | the task's `Title:` line |
| `state` (`working`, `waiting`, `reported`, `failed`, `stopped`) | the session's run state, the newest report |
| `startedAt`, `workedFor` | the session |
| `task` (Markdown) | the spawn task text |
| `session: HomeAgentSessionRef` | see Identity |
| `workspace` (optional) | the spawn tool's workspace, or none (hidden) |
| `lastActivity`, `readAt` | the session's newest message; the person's open of its tab |

The owner source gets one more read and one more event: `agentPeers(of: conversation)` and
`.agentPeer(HomeAgentPeer)`. HomeStore keeps them per conversation (as it keeps `agentMessages`) and
the projection maps a turn's agents to pill rows. The existing `HomeAgentRun` stays the source of
"which turn touched which agent"; `HomeAgentPeer` adds what a pill and the pane need.

## Identity (to agree with a963, Chief teleport, and a964, agent session teleport)

```
HomeAgentSessionRef {
  chief:   the Chief's id (its conversation's owner record)
  peer:    "a963"                       // stable for the agent's whole life
  session: acpmux session uuid          // stable across machines (a964 keeps it on a move)
  place:   { machine id | "cloud" }     // mutable: where it runs now
  epoch:   UInt64                       // bumped by every move
}
```

The **key** is `(chief, peer)`; `session` survives a teleport; `place` and `epoch` change with it. Home
never caches a socket: opening a tab resolves `place` at that moment (`_acpmux/resolve` on this Mac,
the peer's acpmux over the paired route, or the Cloud session API), and an `.agentPeer` event with a
higher `epoch` makes an open tab re-attach where the session went. The asks to a963 and a964:
keep the session uuid across moves, publish the new place and a higher epoch as one event, and keep the
transcript readable from the new place, including the turns from before the move.

## Cloud

Cloud subagents and the Cloud Chief use the same `HomeAgentPeer` and the same pane. The only
difference is the pane's transport. `AgentPaneTransport` gets a second backend over the Cloud session
API: list, transcript page, live events, send and stop, with the same frames. Status, transcript and
composer then work the same for a session on a cloud VM. "Go to workspace" opens the cloud
workspace's link (`cmux://group/…/workspace/…`) when the session has one, else it is hidden.

## Sender labels and the Chief seeing the person's words

- An outgoing prompt carries `_meta.cmux.sender` = `human:<participant>` or `chief:<id>`. acpmux
  stores it with the turn; the pane draws "You" or "Chief" above it. Older turns without it read as
  "Chief" when the Chief sent them (its `tell` and spawn), else "You".
- When the person sends from the pane, Home also posts the text to the Chief as an inbox item through
  the owner (`HomeIntent.agentNote(peer, text)`). The Chief reads it at its next turn, the same channel
  as a report, so it is never woken for it alone.

## Playground (DEBUG: Debug > Agent Messages Playground, "Agents" section)

Pills over the mock owner, and each open style live:

| # | Style | Click does |
|---|---|---|
| A | Right pane with tabs (default) | the agent's chat in the right pane, Go to workspace in its header |
| B | Workspace in a tab | the right pane holds the agent's whole workspace (its terminals and tabs) |
| C | Peek popover | a popover with the last messages and Open |
| D | Cmd-click to workspace | like A; Cmd-click jumps to the workspace |
| E | Inline expand | the pill opens in place in the chat (an accordion), with the composer |
| F | Compact chips | a turn's agents as one wrapped line of small chips, then A |
| G | Two-line pills | a pill shows the newest line under its title, then A |

## Shipping order

1. Playground with the variants (DEBUG only; the shipped fold stays).
2. The default (A + D): pills, the right pane with tabs, the shared composer with sender labels,
   Go to workspace. Red test first (the projection makes one pill per touched agent, under its turn,
   with its state and unread dot; a click opens one tab per agent; a second click selects it).
3. Cloud transport and the move events, with a963 and a964.

## Landing slices (2026-11-03)

Slice 1 ships pills from the data Home already reads, with no new owner read, so it does not wait on
the `HomeAgentPeer` / `HomeAgentSessionRef` agreement with a963 and a964:

- `HomeAgentMessages.inserting` puts ONE agents row (the `.fold` kind, same group id) after the turn
  for one or more messages, and status notes join it (no second "Disconnected (N)" row, no lone
  bubble). Per agent, first-seen order: state = its newest step (task `told` = working, report
  `reported`, status note `stopped`); title = `HomeAgentMessageRow.title(of:)` of the Chief's first
  message to it, else its id. Local and Cloud Chief runs map through the same `HomeAgentRunMapping`.
- The shipped `HomeAgentFoldRowProvider` draws `HomeAgentPills` (`.pill`) for that row; note and Feed
  rows keep the caption line. Unread = `reported` until slice 2 adds `readAt`.
- A click still opens and closes the turn's messages under the pills (no pane yet).

Slice 2 (shipped): a pill click (`ChatController.onAgentPill`) opens `HomeAgentPane` (constructor-injected
over `HomeStore`, tabs keyed by agent id per chat) in a right pane of the Home chat; the chat comes from
`HomeStore.agentThread` (the run rows): task as "Sent via Chief" with Show more, "Worked for" = first to
newest step (to now while it works), the later messages with the Chief's labelled. Opening marks the
agent's newest report seen (`HomeStore.markAgentSeen`, this launch only), so its unread dot clears until a
newer report. "Go to workspace" opens the Chief's own `[aN](cmux://chief/<home>/session/<id>)` link from
its replies (optchat-chief `workspaces::subagent_link`, opened by the existing subagent-link route); no
link in the chat: no button. Pill titles: the `Title:` line, else the first clause at a word edge (~32
characters); the pill clips the rest.

Slice 3 (steps 1 and 2 built in Home; needs owner changes, owned by a963/a964 and the Chief producer):
- Owner part shipped: a963's subagent `place` and `epoch` in host/spawns landed on feat-cmux-next
  (ded88aaa..ad4816c7). Home reads them into `HomeAgentSessionRef`; the session id stays the same across a
  move, and the agent pane follows an agent by its session id and re-attaches where a higher epoch says.
- The composer's send: the person's message must reach the subagent through the Chief and be recorded
  in the Chief's run with its sender. Needs a `tell` input field `from` (or `_meta.cmux.sender`) in
  optchat-chief, and `HomeIntent.agentNote(peer, text)` through the owner so the Chief sees it.
- Labels: `HomeAgentRunMapping` reads `from`, `HomeAgentThread.Entry` carries it, the chat labels You or
  Chief (the `.you` sender and its string already ship).
- Session identity: "Go to workspace" and a live transcript of the subagent's own session need the
  `HomeAgentSessionRef` shape above; the pane only passes the Chief's link through today.

Old plan, slice 2: the pill click (`onPill`, now shipped) -> a constructor-injected `@MainActor @Observable`
`HomeAgentPaneCoordinator` (tabs keyed by (chief, peer), open selects, closing the last hides the
pane), the pane's first content from the same run rows (task as "Sent via Chief", "Worked for" =
report time minus task time, the later messages), and the seen set for the unread dot. "Go to
workspace" waits for the `HomeAgentSessionRef` shape. Slice 3: sender labels and the shared composer
(needs the `_meta.cmux.sender` and `agentNote` owner changes above).
