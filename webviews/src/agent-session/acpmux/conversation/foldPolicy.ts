// Which rows of a transcript fold into one counted line, as data: each row is described by its role
// in a run (a member of some run kind, a quiet row a run carries along, or a row that ends a run),
// and `foldSpans` finds the runs over those descriptors alone. Nothing here reads a row's shape
// beyond `rowRole`, so the span rule (`foldSpans`) and the label table (`RUN_LABELS`) are pure
// functions over plain records and can move to Rust as they are.
//
// Leo, 2026-11-12, on 10-20 "Background command completed" rows in a row inside a finished turn,
// between thoughts, "Sent to" rows, "Received 9 messages" and "Subagent finished": "this is prob
// pretty obvious as fold candidates... tho ig a 'completed' is technically a more special cased
// version?" A completed background command is one run kind of the rule; any row that is the same
// kind of event in a row folds the same way once it has a line in the table below.
//
// The rule:
// - A run starts at a member and goes on over members of the same run kind.
// - A quiet row between two members (a thought, a message sent to or received from another agent,
//   a subagent's end, a reply that draws nothing) does not end the run: it folds into it and its
//   messages count on the line. A quiet row after the run's last member is not the run's, unless
//   it is a member's own (an opened background turn's rows).
// - Anything else ends the run: words for the person, a failure, a card that waits on them.
// - A run of fewer than `minMembers` members draws as its rows did.
import type { StringKey } from "../i18n";
import type { AcpmuxRow } from "../model";
import { isLineRow, LANE_NOTICE_BATCH, MESSAGE_RUN } from "../model";
import { BACKGROUND_TURN, backgroundWeight } from "./backgroundTurns";
import { inboxCounts } from "./inboxNotice";
import { isWaitingMessage } from "./pendingMessages";
import { isThought } from "./thoughts";
import { isSentEntry, toolGroups } from "./toolGroups";
import { isVisiblyEmptyMessage } from "./visibleMessage";
import { SUBAGENT_DONE } from "../subagents/subagentRows";

/// What a member adds to its run's line. `command`: a background shell that completed (its note,
/// or the call that started it marked completed); `finished`: a quiet background turn a task's end
/// woke; `stopped`, `scheduled` and `other` as backgroundRuns.ts counted them before.
export type MemberTally = "command" | "finished" | "stopped" | "scheduled" | "other";

/// The kinds of run the table knows. Each folds only with members of its own kind.
export type RunKind = "background";

/// One row's role in a run, the only thing `foldSpans` reads.
export type FoldRole =
  | { role: "member"; run: RunKind; tally: MemberTally }
  /// `owned`: a row of a member's own (an opened background turn's rows), which goes with the run
  /// even after its last member, so closing the run hides it with its line.
  | { role: "quiet"; sent: number; received: number; owned?: true }
  | { role: "break" };

export type FoldTallies = Record<MemberTally, number> & { sent: number; received: number };

/// A run found over the roles: rows `[from, to)`, `to` one past its last member.
export type FoldSpan = { from: number; to: number; run: RunKind; members: number; tallies: FoldTallies };

const BREAK: FoldRole = { role: "break" };
const QUIET: FoldRole = { role: "quiet", sent: 0, received: 0 };
const OWNED: FoldRole = { role: "quiet", sent: 0, received: 0, owned: true };
const member = (tally: MemberTally): FoldRole => ({ role: "member", run: "background", tally });

const emptyTallies = (): FoldTallies => ({
  command: 0,
  finished: 0,
  stopped: 0,
  scheduled: 0,
  other: 0,
  sent: 0,
  received: 0,
});

/// The runs of `roles` with `minMembers` or more members. One pass; each role is read at most twice
/// (once while a run is scanned, once again when the scan stopped at a break that starts nothing).
export function foldSpans(roles: readonly FoldRole[], minMembers = 2): FoldSpan[] {
  const spans: FoldSpan[] = [];
  let index = 0;
  while (index < roles.length) {
    const first = roles[index]!;
    if (first.role !== "member") {
      index += 1;
      continue;
    }
    const tallies = emptyTallies();
    let members = 0;
    let last = index;
    // Quiet rows wait here until a later member claims them for the run.
    let sent = 0;
    let received = 0;
    let at = index;
    for (; at < roles.length; at += 1) {
      const role = roles[at]!;
      if (role.role === "member" && role.run === first.run) {
        tallies[role.tally] += 1;
        members += 1;
        tallies.sent += sent;
        tallies.received += received;
        sent = 0;
        received = 0;
        last = at;
      } else if (role.role === "quiet") {
        sent += role.sent;
        received += role.received;
        if (role.owned) last = at;
      } else break;
    }
    if (members >= minMembers) spans.push({ from: index, to: last + 1, run: first.run, members, tallies });
    index = last + 1;
  }
  return spans;
}

/// How a run's line reads, as a table: the first entry whose test holds names its words. `n` is the
/// member count; the messages its quiet rows carried follow as phrases of their own.
export const RUN_LABELS: Record<
  RunKind,
  readonly { key: StringKey; when: (tallies: FoldTallies, n: number) => boolean }[]
> = {
  background: [
    // "14 background commands finished": every member a shell that completed.
    { key: "backgroundRun.commandsFinished", when: (tallies, n) => tallies.command === n },
    // "4 background tasks finished": every member a task that ended well.
    { key: "backgroundRun.finished", when: (tallies, n) => tallies.command + tallies.finished === n },
    // "5 background updates": a stopped shell, a scheduled check or another background turn among them.
    { key: "backgroundRun.updates", when: () => true },
  ],
};

export function runLabelKey(run: RunKind, tallies: FoldTallies, n: number): StringKey {
  return RUN_LABELS[run].find((entry) => entry.when(tallies, n))!.key;
}

// ---- Row descriptors. The only part that reads AcpmuxRow; a Rust port maps its own rows here. ----

/// A background shell that ended in the background without failing.
const endedWell = (state: string | undefined) => state === "completed" || state === "stopped";

/// An activity row's role: a member when each of its calls is a background shell that ended there
/// without failing (Claude Code desktop's "Background command completed" on the call's own row),
/// quiet when it only thought or sent messages, else a break. Only a finished turn's row
/// (`settled`): a running turn's rows keep their place as they arrive.
///
/// `sends`: whether to look for messages to other agents among its calls, which groups its calls
/// (toolGroups.ts); without it such a row is a break. `foldBackgroundRuns` asks only for the rows
/// between two members, so a turn without a run never groups its calls here.
function activityRole(row: AcpmuxRow, sends: boolean): FoldRole {
  const items = row.items ?? [];
  let calls = 0;
  let background = 0;
  let stopped = 0;
  let others = false;
  for (const item of items) {
    if (isThought(item)) continue;
    const tool = item.tool;
    if (!tool) {
      // A note the agent wrote between calls is words for the reader.
      if (item.text?.trim()) return BREAK;
      continue;
    }
    calls += 1;
    if (tool.background && endedWell(tool.background.state) && tool.status !== "failed") {
      background += 1;
      if (tool.background.state === "stopped") stopped += 1;
    } else others = true;
  }
  if (calls === 0) return QUIET;
  if (!others) {
    if (row.settled !== true) return BREAK;
    return member(stopped === background ? "stopped" : "command");
  }
  if (background > 0 || !sends) return BREAK;
  // Only messages to other agents ("Sent to …"), each counted on the line.
  let sent = 0;
  for (const group of toolGroups(items)) {
    if (group.type === "item" && isThought(group.item)) continue;
    if (group.type === "sendGroup") sent += group.entries.length;
    else if (isSentEntry(group)) sent += 1;
    else return BREAK;
  }
  // A send that failed or still runs stays in sight.
  for (const item of items) if (item.tool && item.tool.status !== "completed") return BREAK;
  return { role: "quiet", sent, received: 0 };
}

/// Another agent's message, a notice the agent was woken by, or an inbox batch: quiet, counted as
/// received. A person's message, a fire, one still waiting to be read or a reply card is a break.
function userRole(row: AcpmuxRow): FoldRole {
  if (row.received || !isLineRow(row) || isWaitingMessage(row)) return BREAK;
  const incoming = row.incoming;
  if (!incoming) return BREAK;
  if (incoming.kind === "notice") return QUIET;
  if (incoming.kind === "inbox")
    return { role: "quiet", sent: 0, received: Math.max(1, inboxCounts(incoming.notice).messages) };
  if (incoming.kind === "message" && !incoming.message.fromPerson && incoming.message.notice?.severity !== "fire")
    return { role: "quiet", sent: 0, received: 1 };
  return BREAK;
}

/// Each row kind's rule. A kind not listed ends a run.
const ROLE_BY_KIND: Record<string, (row: AcpmuxRow) => FoldRole> = {
  backgroundTask: (row) => {
    const state = row.backgroundTask?.state;
    return state === "completed" ? member("command") : state === "stopped" ? member("stopped") : BREAK;
  },
  [BACKGROUND_TURN]: (row) => {
    const turn = row.background;
    if (!turn || turn.running || turn.quiet !== true || backgroundWeight(turn)) return BREAK;
    if (turn.trigger === "task_notification") return member("finished");
    return member(turn.trigger === "scheduled" ? "scheduled" : "other");
  },
  activity: (row) => activityRole(row, true),
  user: userRole,
  // "Subagent finished": the helper's end is the agent's business; a failed one stays in sight.
  [SUBAGENT_DONE]: (row) => ((row.subagents ?? []).some((agent) => agent.state === "failed") ? BREAK : QUIET),
  // "Received 9 messages".
  [LANE_NOTICE_BATCH]: (row) => ({ role: "quiet", sent: 0, received: row.laneNoticeBatch?.rows.length ?? 1 }),
  // A reply that draws nothing.
  assistant: (row) => (!row.streaming && isVisiblyEmptyMessage(row) ? QUIET : BREAK),
  // A folded run of messages between agents (messageRuns.ts): quiet when it only carried messages,
  // counted as they are; one that also did work, failed or still runs ends the run.
  [MESSAGE_RUN]: (row) => {
    const run = row.messageRun;
    if (!run || run.work.length || run.failed || run.running) return BREAK;
    return { role: "quiet", sent: run.sent, received: run.received };
  },
};

/// `row`'s role in a run. `owners`: the ids of the background turn lines of earlier members, whose
/// opened rows (`inBackground`) go with the run.
/// `cheap`: an activity row that is no member is a break, without grouping its calls (`activityRole`).
export function rowRole(row: AcpmuxRow, owners?: ReadonlySet<string>, cheap = false): FoldRole {
  if (row.inBackground !== undefined && owners?.has(row.inBackground)) return OWNED;
  if (row.incoming?.kind === "hidden") return QUIET;
  if (cheap && row.kind === "activity") return activityRole(row, false);
  return ROLE_BY_KIND[row.kind]?.(row) ?? BREAK;
}

/// The roles of `rows` for `foldSpans`, in two passes: every row cheaply, then, only when two or
/// more members came up, the activity rows between the first and the last member in full. `owners`
/// gathers the background turn ids of members, whose opened rows go with their run.
export function rowRoles(rows: readonly AcpmuxRow[], memberLine: (row: AcpmuxRow) => string | undefined): FoldRole[] {
  const owners = new Set<string>();
  let first = -1;
  let last = -1;
  let members = 0;
  const roles = rows.map((row, index) => {
    const role = rowRole(row, owners, true);
    if (role.role === "member") {
      const line = memberLine(row);
      if (line !== undefined) owners.add(line);
      if (first < 0) first = index;
      last = index;
      members += 1;
    }
    return role;
  });
  if (members < 2) return roles;
  for (let index = first + 1; index < last; index += 1)
    if (rows[index]!.kind === "activity" && roles[index]!.role === "break")
      roles[index] = rowRole(rows[index]!, owners);
  return roles;
}
