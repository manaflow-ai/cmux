# Comment round-trip on iOS and Cloud sessions

Goal: cmuxterm-hq `goals/extend-comment-round-trip-beyond.md`. Leo: "His order is a pattern: fix the case he named,
then every other place and surface breaking the same rule" / "there's no point of me simply being a fucking relay."

The round-trip that works today (diff, browser, terminal on the Mac, `comment_threads_journey.rs`): the comment is
saved as a thread in the session host's `diff_comments` store (`diff.comments.save`), sent with a threaded
`diff.comments.send` (the host renders the prompt and hands it to its own acpmux via `acp_prompt_diff_comments`,
which takes only a session that acpmux runs itself, not a peer's), the agent answers with
`cmux git comments reply|resolve` (the same host's store), and the page polls `diff.comments.list` (2 s).

## Cloud-machine sessions: routed by construction, unproven

Read at feat-cmux-next 6ba08cee:

- All three Mac surfaces pick their store with `DiffPageService.gitLink(for: chat.tab)`. For a chat whose
  `agentTabs.hostKind` is `.remote` it returns `agentGit.link(for: machines.agentDaemon(forTab:))`: the Cloud
  machine's own session host, never this Mac's (a missing link refuses).
- The terminal (`TerminalHandlers.commentTarget`, which takes `.pty` and `.remoteTerminal`) and the browser
  (`BrowserDesignModeController.threadTarget`) both gate on `link.supportsDiffCommentThreads`: the Cloud host's
  handshake must advertise `diff-comments-threads-v1`, and Labs `labs.commentThreads` must be on.
- On the machine, `acp_prompt_diff_comments` reaches the machine's acpmux, which runs the Cloud chat itself (no
  `peer`), so the prompt is taken. The agent's `cmux git comments reply` runs on the machine against the same
  host and store, so the reply lands in the thread the Mac polls.

What is missing: (1) proof. No test or probe runs the round-trip against a Cloud machine's host, and nothing
reports whether the daemon in the production machine image advertises `diff-comments-threads-v1`; if it does not,
every Cloud chat silently falls back to the chip/plain send (`TerminalToChatPlaceholders.reason`). (2) A Cloud chat
whose tab classifies as local (a session the Mac's acpmux lists as a `peer`) is refused as `no_session` ("runs
no session X"), which does not say the session is on another machine.

Next:
- A `comment-threads-journey` leg on a Cloud machine: start one with the probe's own login, run the journey
  binary's diff/terminal round-trip against the machine's host (`cmux vm exec` + `cmux git comments`), and report
  the handshake's capabilities. This is the per-surface row for "cloud".
- When the session is a peer's, refuse it with its own reason naming the machine (`agent_message_acpmux.rs`
  `session_info`: return the peer, not a bare Unreachable).

## iOS app: no comment surface at all

- `Packages/iOS` has no comment or thread UI and no `diff.comments.*` call. The phone talks to the Mac's
  `mobile.*` RPCs (`CmuxMobileRPC`) and opens Mac chats through acpmux with its own credential
  (`cmux-mobile-host-core` `credentials`); it never reaches the session host's resource RPCs.
- What exists: the conversation's inline reply (`CmuxConversation` `ConversationReplyThread`, Messages-style quote
  plus reply). That is where the person gives place-specific feedback on the phone, and its answer comes back in
  the chat stream, not in a thread.

Design (new logic in Rust): the inline reply becomes a thread with `surface: "ios"`, `place` = the quoted
message's id and a one-line excerpt, saved in the chat's session host store, and sent threaded. Two ways to reach
the store from the phone:
1. Through acpmux (preferred: the phone already holds an acpmux credential for the chat): an acpmux method that
   forwards `diff.comments.save|send|list|thread` for that session to the session host it runs on, refused for
   sessions the credential does not cover.
2. A `mobile.comments.*` RPC on the Mac's mobile host that calls `DiffAgentGit` for the chat's tab (Swift
   glue only, the rules stay in the daemon).
The iOS view shows the thread's agent reply under the quote (the reply line already draws it), polling `list` as
the Mac pages do.

The work in order: the Cloud proof (a probe row, no product change if the image is current), then the peer refusal,
then the iOS path (1).
