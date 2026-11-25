// The fields the view reads that the store and adapter do not give as v1 does yet (decision 233):
// each with its home (decision 229, FIELDS.md) and the row that builds it. The parity test fails
// when a field off this list differs from v1 over the corpus, and when a field on it no longer
// differs anywhere in the corpus, so the list only shrinks. Empty is a done-when of row 13.
// A key is `<view row kind>.<field>`; a tool call's fields are `tool.<field>`.

export type Home = "a" | "b" | "c" | "d" | "e" | "f" | "g";
export type Builder = "2c" | "2d" | "A0" | "row 11";

/// `covers` names the FIELDS.md names the entry stands for beside its own field.
export type NotYet = { field: string; home: Home; builder: Builder; note: string; covers?: readonly string[] };

export const NOT_YET: readonly NotYet[] = [
  {
    field: "assistant.turnStartedAtMs",
    home: "b",
    builder: "2c",
    note: "the group row's start, in ms (decision 231)",
  },
  {
    field: "turnSummary.turnStartedAtMs",
    home: "b",
    builder: "2c",
    note: "the group row's start, in ms (decision 231)",
  },
  { field: "tool.startedAt", home: "a", builder: "2c", note: "in ms on tool rows (decision 231)" },
  { field: "tool.endedAt", home: "a", builder: "2c", note: "in ms on tool rows (decision 231)" },
  {
    field: "tool.approved",
    home: "a",
    builder: "2c",
    note: "an approval reads on its call; the ask row draws no receipt for it",
  },
  {
    field: "tool.provenance",
    home: "a",
    builder: "2c",
    note: "Claude's tool name (`_meta.claude.tool`), with Claude's title and kind",
    covers: ["title", "kind"],
  },
  // The row head's `at` is in seconds; v1 keeps the record's ms.
  { field: "user.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "assistant.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "tool.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "turnSummary.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  {
    field: "row:permissionRecord",
    home: "a",
    builder: "A0",
    note: "an approved ask whose call has no tool row: v1 keeps its receipt, the adapter draws none (parity seq 53-54)",
  },
];

/// The fields FIELDS.md has under "Not yet" that no corpus row shows, so the parity test cannot
/// see them differ (decision 259). Each leaves this list for `NOT_YET` when a corpus line shows it;
/// the parity test fails while the corpus shows one still here. A key is `<kind>.<field>` for a
/// field of a view row, `row:<kind>` for a record that is a row of its own, `snapshot.<field>` or
/// `queue.<field>` for the snapshot's, and `group.<field>` for a group row's (home b), which the
/// view reads through its turn shaping: no v1 row shows those, so the corpus check cannot fail on
/// them, and they leave this list when the page of turns or 2c builds them.
export const NOT_IN_CORPUS: readonly NotYet[] = [
  // Row heads and user rows (2c).
  { field: "user.seq", home: "a", builder: "2c", note: "`seq` on forkable rows" },
  { field: "assistant.assistantPhase", home: "a", builder: "2c", note: "Codex's message phase" },
  { field: "user.from", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.author", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.sentFrom", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.inlineParts", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.pasted", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.agentText", home: "a", builder: "2c", note: "decision 236" },
  { field: "user.continues", home: "a", builder: "2c", note: "decision 236" },
  // Ask rows for a question or a secret; the corpus has only permission asks.
  { field: "questionRecord.decision", home: "a", builder: "2c", note: "a question's answer" },
  { field: "questionRecord.answeredBy", home: "a", builder: "2c", note: "who answered a question" },
  { field: "snapshot.permission", home: "c", builder: "2c", note: "the ask that waits" },
  { field: "snapshot.permissionsWaiting", home: "c", builder: "2c", note: "from the ask rows" },
  { field: "snapshot.permissionsQueued", home: "c", builder: "2c", note: "from the ask rows" },
  { field: "snapshot.permissionGroups", home: "c", builder: "2c", note: "its `groups` of asks, from the ask rows" },
  { field: "snapshot.secret", home: "c", builder: "2c", note: "a secret ask" },
  // The turn-end notice.
  { field: "turnSummary.checkpoint", home: "a", builder: "2c", note: "the turn's checkpoint" },
  { field: "turnSummary.stopForced", home: "a", builder: "2c", note: "a stop that was forced" },
  { field: "turnSummary.continued", home: "a", builder: "2c", note: "a turn that went on" },
  { field: "turnSummary.retry", home: "a", builder: "2c", note: "the turn's retry" },
  { field: "turnSummary.failedAgain", home: "a", builder: "2c", note: "a retry that failed too" },
  // Records as rows, patched by a later event.
  { field: "row:compaction", home: "a", builder: "2c", note: "reason, error, preTokens, postTokens" },
  { field: "row:failover", home: "a", builder: "2c", note: "from, to" },
  { field: "row:recap", home: "a", builder: "2c", note: "key, awayMs, since" },
  { field: "row:policyUnenforced", home: "a", builder: "2c", note: "policy" },
  { field: "row:planBuild", home: "a", builder: "2c", note: "a plan's build" },
  { field: "row:memory", home: "a", builder: "2c", note: "a memory offer" },
  { field: "row:coach", home: "a", builder: "2c", note: "a prompt coach" },
  { field: "row:presetApproval", home: "a", builder: "2c", note: "a preset's approval" },
  { field: "row:offers", home: "a", builder: "2c", note: "session offers" },
  { field: "row:received", home: "a", builder: "2c", note: "a received message" },
  { field: "row:agentPair", home: "a", builder: "2c", note: "an agent pair" },
  { field: "row:backgroundTask", home: "a", builder: "2c", note: "a background task" },
  { field: "row:incoming", home: "a", builder: "2c", note: "sender, message, kind" },
  { field: "row:inboxThread", home: "a", builder: "2c", note: "threadId, sender, preview, newest, count, promptIds" },
  { field: "row:workflow", home: "a", builder: "2c", note: "a row or a patch; 2c decides" },
  { field: "row:promptSuggestion", home: "a", builder: "2c", note: "a row or a patch; 2c decides" },
  { field: "assistant.answersPerson", home: "a", builder: "2c", note: "on a text row" },
  // Tool rows.
  { field: "tool.locations", home: "a", builder: "2c", note: "the call's locations" },
  { field: "tool.exitCode", home: "a", builder: "2c", note: "a command's exit code" },
  { field: "tool.background", home: "a", builder: "2c", note: "a call run in the background" },
  { field: "tool.reaction", home: "a", builder: "2c", note: "the call's reaction" },
  { field: "tool.inputPath.canonical", home: "a", builder: "2c", note: "the canonical path" },
  // Sub rows and a background turn.
  { field: "snapshot.subagentProgress", home: "c", builder: "2c", note: "from the open sub rows" },
  {
    field: "group.inBackground",
    home: "a",
    builder: "2c",
    note: "`background_turn`; not in decision 231's table, 2c decides where",
  },
  // The group row (home b).
  { field: "group.tasks", home: "b", builder: "2c", note: "the started chats, at most 16 (decision 241)" },
  { field: "group.tasksTotal", home: "b", builder: "2c", note: "when there are more than 16" },
  { field: "group.answer", home: "b", builder: "2c", note: "for answerId and turnCopy" },
  { field: "group.ask", home: "b", builder: "2c", note: "the next step" },
  { field: "group.walkthrough", home: "b", builder: "2c", note: "the walkthrough's rowId" },
  { field: "group.changedFiles", home: "b", builder: "2c", note: "the turn's changed files" },
  { field: "group.workedMessages", home: "b", builder: "2c", note: "sent, received" },
  { field: "group.previous", home: "b", builder: "2c", note: "a count" },
  { field: "group.workedRuns", home: "b", builder: "2c", note: "per-kind counts, at most 8" },
  { field: "group.merged", home: "b", builder: "2c", note: "a count and at most 8 ids" },
  { field: "group.backgroundRun", home: "b", builder: "2c", note: "a count and at most 8 ids" },
  { field: "group.foldRun", home: "b", builder: "2c", note: "first rowId and count, at most 8" },
  { field: "group.messageRun", home: "b", builder: "2c", note: "first rowId and count, at most 8" },
  { field: "group.joined", home: "b", builder: "2c", note: "first rowId and count, at most 8" },
  // The open group row's live state (home c).
  { field: "snapshot.isWorking", home: "c", builder: "2c", note: "working, retrying or stopping" },
  { field: "snapshot.stopping", home: "c", builder: "2c", note: "the open group row's state" },
  { field: "snapshot.turnTokens", home: "c", builder: "2c", note: "patched at most once a second" },
  { field: "snapshot.turnTokenSplit", home: "c", builder: "2c", note: "patched at most once a second" },
  { field: "snapshot.retriedMs", home: "c", builder: "2c", note: "the retry's time" },
  // The queue (2d, decision 232).
  { field: "queue.next", home: "d", builder: "2d", note: "a flag" },
  { field: "queue.waking", home: "d", builder: "2d", note: "a flag" },
  { field: "queue.heldByStop", home: "d", builder: "2d", note: "a flag" },
  { field: "queue.awaitingOwner", home: "d", builder: "2d", note: "a flag" },
  { field: "queue.retry", home: "d", builder: "2d", note: "a flag" },
  { field: "queue.images", home: "d", builder: "2d", note: "the entry's images" },
  { field: "queue.message", home: "d", builder: "2d", note: "the entry's message" },
  { field: "row.queuedMessage", home: "d", builder: "2d", note: "the view row's queued message" },
  { field: "queue.why", home: "d", builder: "2d", note: "ran, withdrawn or declined" },
  { field: "snapshot.queueWithdrawn", home: "d", builder: "2d", note: "from the removal's `why`" },
  { field: "snapshot.retryable", home: "d", builder: "2d", note: "maybe 2c; not decided" },
  { field: "snapshot.retryTarget", home: "d", builder: "2d", note: "maybe 2c; not decided" },
  { field: "snapshot.resumable", home: "d", builder: "2d", note: "maybe 2c; not decided" },
  { field: "snapshot.continuable", home: "d", builder: "2d", note: "maybe 2c; not decided" },
  { field: "snapshot.since.turns", home: "d", builder: "2d", note: "turns ended since the seen row; not decided" },
  // The architect's.
  { field: "snapshot.presence", home: "f", builder: "A0", note: "with typing and the read mark (decision 234)" },
  { field: "snapshot.earlierPrompts", home: "d", builder: "A0", note: "a page of turns (decision 235, 6d)" },
  { field: "row:frame", home: "b", builder: "A0", note: "untraced" },
  { field: "row:laneNoticeBatch", home: "b", builder: "A0", note: "untraced" },
  { field: "row:subagentReport", home: "b", builder: "A0", note: "untraced" },
  { field: "row:subagentReportFirst", home: "b", builder: "A0", note: "untraced" },
];
