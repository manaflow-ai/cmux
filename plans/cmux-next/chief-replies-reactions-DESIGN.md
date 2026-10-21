# Chief replies and reactions

User (2026-10-20): the Chief must reply to the exact message it answers, react
instead of writing when a reply would only say "ok", and show which subagents
(aN) each message started. Home's iMessage UI already draws threads
(`reply_to` + `thread_root`, MessagesLab `ThreadMode`) and tapbacks
(`HomeReaction`, iOS `HomeTapbackPicker`). The conversation model already has
`reaction.add` and threaded `message.send`. The gap is the Chief host
(`Native/OptChat/optchat-chief`).

## What exists

- Every turn reply names the messages it answers (`answers`, E22).
- A spawn record keeps the messages of the turn that spawned it
  (`SpawnRecord.answers`), and a report turn answers them again.
- Only a group conversation threads a reply (`membership::thread_target`). The
  Chief's DM never does, so a late reply or a report reads as if it answers the
  newest message.

## Decisions

1. **Threads in the DM (auto).** A turn reply goes into the thread of the
   last user message it answers when that message is no longer the newest one
   in the conversation (another message came after it, or a reply waits in the
   outbox). A reply right under its message stays at the top level, as in
   iMessage. Report turns are therefore almost always threaded under the
   message that started the work. Setting `replies.thread`: `auto` (default),
   `always`, `never`.
2. **The root survives restarts.** A user message that is itself a thread
   reply keeps its root in `HostState.message_roots` (saved, at most 512
   entries). A top-level message is its own root, so it needs no entry.
3. **Refused thread, no lost reply.** When the owner refuses a threaded send
   (unknown or bad root), the same text goes once at the top level under
   `<key>:top`.
4. **Two Chief tools** (Chief only, not subagents), both taking the message id
   the Chief sees in its view:
   - `react {id, reaction}`: `like`, `love`, `laugh`, `emphasize`,
     `question`, `dislike`, or `ack` (= like). Posts `reaction.add` on that
     message. Use it instead of an "ok"-only reply.
   - `reply {id, text}`: posts `text` now, in the thread of message `id`. Use
     it when one turn answers several messages separately.
   The id goes from view id to `<conversation>#<seq>` (`messages.conv_msg`),
   then to the owner's message id (`history`). A line with no conversation
   message (a note, a report) is refused with a clear error.
5. **A tell links too.** `tell` during a turn records the turn's messages on
   that subagent (`SubRecord.answers`). Its next report answers those messages,
   not only the spawn's ones.
6. **Prompt.** The Chief's default "Turns" paragraph adds: reply short; react
   (`ack`) instead of writing when there is nothing to say; answer separate
   asks with `reply`. The user's own instructions still come after it and win.

## Shared data (a209 prompt tracker, a203 spawn/messaging)

`host.json`: `spawns.<sN>.answers` (message ids that started the spawn) and
`spawns.<sN>.subs[].answers` (message ids of the last tell). The owner
conversation has `answers`, `reply_to` and `thread_root` on every Chief reply.
These are the prompt-to-agent links. Read them; do not infer them from the
order of turns.

## Not in scope

- New UI: Home (macOS and iOS) already draws threads and tapbacks from any
  author.
- The Cloud Chief uses the same host code. Its owner gets the same ops through
  `cloud-conversation-op`. Whether the cloud owner accepts an agent's
  `reaction.add` is not checked here.

## Tests (failing first)

`tests/replies_reactions.rs`, with the fake owner harness:
- a late reply to an older message is threaded under it; an adjacent one is not;
- a report turn is threaded under the message that spawned the work;
- `react` posts `reaction.add` on the right message, and `ack` is a like;
- `reply` posts into that message's thread;
- a thread the owner refuses falls back to a top-level reply.
