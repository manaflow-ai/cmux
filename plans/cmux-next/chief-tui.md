# Chief TUI and scriptable Chief client

Lawrence (Oct 22): "i think we should have TUI version of cmux chief/home, that has feature parity
of everything, such that it is easier for coding agents to test chief functionality."

## Goal

One terminal client of Chief/Home that a person can use and that a coding agent can script in a
test. It shows the same chats as Home, through the same API Home uses, and it works with the local
Chief and with the hosted Cloud Chief.

## What exists

`cmux chief` (cmux-tui `src/cli/chief/`) already is a client of the session daemon's conversation
owner. It sends as `user_local`, so Home shows its messages and the brain wakes as for Home:

- On a terminal: an inline chat of the one Chief conversation (`agent_mux`), with live drafts,
  typing, subagent links as OSC 8 hyperlinks, `/model`, `/effort`, `/thoughts`, Ctrl+C stop.
- Pipe mode (`-p TEXT` or stdin): send one message, print the reply, exit when the turn ends.
- `list | get | new | adopt | edit | delete | history | undo`: the Chief registry.
- `engine`, `stop`, `shutdown`, `move`, `usage`.

What is missing for Home parity: other chats (each Chief's chat, groups, DMs), replies and threads,
reactions, attachments, Cloud chats, and a non-interactive way for a test to read state and wait
for a specific event without parsing a terminal.

## Design

### One backend, two owners

A new `ChatClient` (`backend.rs`) wraps one daemon connection and exposes the operations Home uses.
Each call goes to the local owner or to the daemon's cloud proxy. The wire is the daemon's own API.
There is no second store.

| Operation | Local owner | Cloud owner (`--cloud`) |
| --- | --- | --- |
| list chats | `conversation.list` | `cloud-inbox-list` |
| snapshot | `conversation.get` | `cloud-conversation-snapshot` |
| history | `conversation.history` | `cloud-conversation-history` |
| thread | `conversation-thread` | `cloud-conversation-thread` |
| send, reply, react, edit, retract, read cursor | `conversation-op` | `cloud-conversation-op` |
| upload attachment | `conversation-attachment-upload` | `cloud-attachment-upload` |
| live events | `conversation.events` stream | `subscribe` + `cloud-conversation-subscribe` |

Cloud events (`cloud-conversation-changed`, `-resynced`, `-typing`) are mapped to the item shapes
of `conversation.events` (`snapshot`, `message`, `message_updated`, `read_cursor`, `typing`,
`conversation`). Then the chat view, the turn watcher and the scripts read one event shape for both
owners.

### Cloud Chief access

The daemon gives the cmux app's cloud lease only to the verified app (`cloud-lease-app-only-v1`,
cmux#13742). A CLI must not get the user's cloud session from the app, and this design does not
change that rule. For a Cloud chat, the CLI uses a daemon where no app holds a lease, and it sets
its own lease:

- `--cloud-api ORIGIN` with `--cloud-token-file FILE` (or `CMUX_CLOUD_ACCESS_TOKEN`) sets a bearer
  lease (`cloud-session-set`) on that daemon.
- `--cloud-api ORIGIN --cloud-auth tailscale` sets a self-hosted (tailnet) lease, with no token.
- Without these flags, `--cloud` uses the lease that the daemon already has.
- If the app holds the lease, the daemon refuses with `forbidden`. The CLI then tells the person to
  use an isolated session (`--session NAME`).

Cloud ops go with no `origin` (the owner records `cli`). The CLI never sends `origin: "user"`.

### Chats and Chiefs

A chat is a conversation id. A chat's Chief is its agent participant with `agent_class: "mux"`.
When there is no such participant, `agent_mux` is the Chief. The turn watcher and the drafts follow
that participant, so every Chief's chat works, not only `agent_mux`.

The default chat stays the oldest conversation with `agent_mux` (Home's rule). `--chat ID` selects
another chat. `cmux chief new` (the registry) creates a Chief. `cmux chief chats` lists the chats
with each chat's Chief, last seq and unread count.

### Scriptable verbs (non-interactive)

Every verb prints plain text, or one JSON value with `--json`. All verbs take `--chat ID` and
`--cloud`. Exit codes: 0 ok, 1 refused, 2 bad arguments, 3 transport, 124 timeout.

```text
cmux chief chats                         list chats (id, title, chief, last_seq, unread)
cmux chief read [--last N] [--before SEQ] [--thread MSG]
                                         messages, oldest first, with reactions and reply refs
cmux chief send TEXT|- [--reply-to MSG[:PART]] [--attach FILE]... [--wait] [--timeout S]
                                         send as the person; --wait prints the Chief's replies
                                         and exits when the turn that answers ends
cmux chief react MSG EMOJI|TAPBACK [--part N] [--remove]
cmux chief edit MSG TEXT | retract MSG | mark-read [SEQ]
cmux chief wait [--after SEQ] [--from chief|me|ANY_ID] [--text SUBSTR] [--idle] [--timeout S]
                                         block until a matching message arrives (or the Chief
                                         is idle); print it
cmux chief events [--tail N]             the live event stream as JSON lines (normalized items)
```

`MSG` is a message id (`msg_…`) or `#SEQ`. Tapbacks: `love like dislike laugh emphasize question`.
Any other value is an emoji reaction.

With these verbs a test needs no terminal:

```bash
seq=$(cmux --json chief send "count to 3" | jq .seq)
cmux --json chief wait --after "$seq" --from chief --timeout 120 | jq -r .text
cmux chief react "#$seq" like
cmux --json chief read --last 5
```

### Chat on a terminal

The inline chat stays, because it keeps the chat in the scrollback. It adds:

- A short `#SEQ` in each message header. Reactions show below the body
  (`👍 1 · ♥ 2`). A reply shows its parent (`↳ #12`), and a thread root shows its reply count.
- `/chats` lists chats with their numbers; `/open N|ID` switches to that chat (a new stream, the
  last N messages first).
- `/reply #SEQ TEXT`, `/react #SEQ EMOJI`, `/unreact #SEQ EMOJI`, `/thread #SEQ`,
  `/attach PATH [TEXT]`, `/edit #SEQ TEXT`, `/retract #SEQ`.
- `/new NAME` creates a Chief (registry `new`) and opens its chat when the chat exists.
- The header names the chat and its owner (local or cloud).

### Tests

- Unit tests (`cli/chief/tests.rs`): argument parsing, the `#SEQ` reference parser, the reaction
  parser, the cloud-event mapping, and rendering of reactions and replies.
- Integration tests (`tests/cli/chief_script.rs`) against a real headless daemon with a fake brain,
  as `tests/cli/chief.rs` does: `chats`, `send --wait`, `wait --from chief`, `react` and its
  result in `read --json`, `send --reply-to`, `read --thread`, `send --attach` with the uploaded
  attachment part, and `--chat` on a second Chief's chat.
- A cloud integration test with a loopback fake cloud (as `cloud_lease_gate.rs` does): the CLI sets
  its own lease and lists the inbox through the daemon.

### Out of scope here

- Questions (agent permission cards) are shown as text. An `answer` verb comes later.
- Typing a token for the user's real cmux Cloud account: a person mints it. The CLI only reads a
  token file or a tailnet server.
- Full-screen layout (sidebar of chats). The inline chat with `/chats` gives the same functions and
  stays in the scrollback.
