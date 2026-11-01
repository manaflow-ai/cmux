// A run of one-line rows that carries messages between agents folds into one line, as a run of
// tool calls does (Leo, 2026-11-01, on a turn of "Sent to" rows, reads, another agent's line, a
// compaction and "Ran a command, read a file", each on its own row: "this should be collapsible").
// The line reads what the run did ("Sent 5 messages, ran 2 commands, read a file, received a
// message") and opens to the rows exactly as they drew before, each message on its own row (Leo,
// 2026-10-31: "you guys should just render them all separately", cmux#29800, still holds open).
//
// Only where a turn's runs fold (the Codex-style runs, and a Claude turn's per-run folding,
// turns.ts `shapeTurn`): the members are those folded runs, another agent's lines and the turn's
// compactions between them, which fold with the turn's work (Leo, 2026-10-21: fold the work,
// "compaction and subagent/system notices" among it). Prose, a steer, a card kept in sight and the
// live line end the run. The line is a fold of the transcript's fold set, like a background turn's
// line (backgroundTurns.ts): its rows follow it while open and never draw while closed, so each
// keeps its own estimate and the scroll never jumps.
import { isLineRow, MESSAGE_RUN, type AcpmuxActivity, type AcpmuxMessageRun, type AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { isWaitingMessage } from "./pendingMessages";
import { isFailed, isRunning, runStretches, toolGroups, type ToolGroup } from "./toolGroups";
import { toolRunPhrases } from "./toolRunSummary";
import type { Folds } from "./viewFolds";

export const messageRunRowId = (firstId: string) => `${MESSAGE_RUN}-${firstId}`;

/// A message to another agent in a run: Claude Code's SendMessage and the other message cards, a
/// shell or MCP `acpmux send` (one per message of a batch), a sub-session's `send_message`.
const isSend = (group: ToolGroup) =>
  group.type === "message" || group.type === "send" || (group.type === "subsession" && group.call.tool === "send");

/// Another agent's one-line message in the turn (IncomingMessageCard.tsx, InboxNoticeCard.tsx). One
/// the agent has not read yet leaves for the waiting group (pendingMessages.ts), never into a run.
const isReceivedLine = (row: AcpmuxRow) => row.kind === "user" && isLineRow(row) && !isWaitingMessage(row);

/// What one member adds to its run's line, or undefined for a row that ends the run.
type Member = { lines: number; sent: number; received: number; work: AcpmuxActivity[]; failed: number; running: boolean };

function member(row: AcpmuxRow): Member | undefined {
  if (row.kind === "compaction")
    return { lines: 1, sent: 0, received: 0, work: [], failed: 0, running: row.compaction?.state === "running" };
  if (isReceivedLine(row)) {
    // An inbox notice is one line per thread (InboxNoticeCard.tsx).
    const n = row.incoming?.kind === "inbox" ? Math.max(1, row.incoming.notice.threads.length) : 1;
    return { lines: 1, sent: 0, received: n, work: [], failed: 0, running: false };
  }
  // A folded run (codexRuns, shapeTurn): its lines as ToolRows draws them (`runStretches`).
  if (row.kind !== "activity" || row.foldRun !== true || !row.items?.length) return undefined;
  const groups = toolGroups(row.items);
  // A card that stays in sight for its own sake (a sub-session started or waited on, a dispatch)
  // keeps the run open around it; only messages fold.
  if (
    groups.some(
      (group) =>
        group.type === "subsessionGroup" ||
        group.type === "dispatch" ||
        (group.type === "subsession" && group.call.tool !== "send"),
    )
  )
    return undefined;
  let lines = 0;
  for (const stretch of runStretches(row, groups)) lines += stretch.fold ? 1 : stretch.groups.length;
  const sent = groups.filter(isSend).length;
  const sentItems = new Set(groups.flatMap((group) => (isSend(group) && "item" in group ? [group.item] : [])));
  const work = row.items.filter((item) => item.tool && !sentItems.has(item));
  return {
    lines,
    sent,
    received: 0,
    work,
    failed: row.items.filter((item) => item.tool && isFailed(item.tool)).length,
    running: row.items.some((item) => item.tool && isRunning(item.tool)),
  };
}

/// `rows` with each run that carries a message and draws two or more lines folded under its line:
/// the line alone while closed, the line and its rows while open (`expanded` holds the line's id).
/// A run without a message, or of one line, is `rows` as they were.
export function foldMessageRuns(rows: AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  let index = 0;
  while (index < rows.length) {
    let end = index;
    const parts: Member[] = [];
    for (let part = member(rows[end]!); part && end < rows.length; part = rows[++end] && member(rows[end]!))
      parts.push(part);
    if (end === index) {
      out?.push(rows[index]!);
      index += 1;
      continue;
    }
    const members = rows.slice(index, end);
    const lines = parts.reduce((sum, part) => sum + part.lines, 0);
    const sent = parts.reduce((sum, part) => sum + part.sent, 0);
    const received = parts.reduce((sum, part) => sum + part.received, 0);
    if (lines < 2 || sent + received === 0) {
      out?.push(...members);
      index = end;
      continue;
    }
    out ??= rows.slice(0, index);
    const first = members[0]!;
    const id = messageRunRowId(first.id);
    const open = expanded.has(id);
    const run: AcpmuxMessageRun = {
      sent,
      received,
      work: parts.flatMap((part) => part.work),
      failed: parts.reduce((sum, part) => sum + part.failed, 0),
      running: parts.some((part) => part.running),
      // A folded copy of an edit run is drawn under its source row's id and a suffix (turns.ts FOLDED).
      rows: members.flatMap((row) => [row.id, ...(row.id.endsWith(":fold") ? [row.id.slice(0, -5)] : []), ...(row.joined ?? [])]),
    };
    out.push({
      id,
      // Moves with every member's version and the open state: the memoized line and the height
      // cache compare versions only.
      version: (members.reduce((sum, row) => (sum * 31 + row.version) % 1_000_003, members.length) * 2 + (open ? 1 : 0)),
      at: first.at,
      kind: MESSAGE_RUN,
      foldOpen: open,
      messageRun: run,
      ...(first.settled && { settled: true }),
    });
    if (open) out.push(...members);
    index = end;
  }
  return out ?? rows;
}

/// The open message-run lines among a turn's rows `rows[start..end)`, which a cached turn compares.
/// A line's id is its first member's (a folded copy of an edit run keeps a suffix, turns.ts FOLDED).
export function openMessageRuns(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  let open = "";
  for (let at = start; at < end; at += 1) {
    const id = messageRunRowId(rows[at]!.id);
    if (expanded.has(id)) open += `${id} `;
    if (expanded.has(`${id}:fold`)) open += `${id}:fold `;
  }
  return open;
}

/// The message-run line among `drawn` that folds the row `rowId` away, so Find or a link opens it.
export function messageRunFoldFor(drawn: readonly AcpmuxRow[], rowId: string): string | undefined {
  for (const row of drawn) if (row.kind === MESSAGE_RUN && !row.foldOpen && row.messageRun?.rows.includes(rowId)) return row.id;
  return undefined;
}

/// The line's words, in the order a reader takes them in: "Sent 5 messages, ran 2 commands, read a
/// file, received a message". The work between is counted as a run of tool calls counts
/// (toolRunSummary.ts).
export function messageRunSummary(t: Translate, run: AcpmuxMessageRun): string {
  const phrases = [
    ...(run.sent ? [run.sent === 1 ? t("messageRun.sent.one") : t("messageRun.sent.other", { n: run.sent })] : []),
    ...toolRunPhrases(t, run.work),
    ...(run.received
      ? [run.received === 1 ? t("messageRun.received.one") : t("messageRun.received.other", { n: run.received })]
      : []),
  ];
  const text = phrases.join(t("toolRun.separator"));
  return text.charAt(0).toUpperCase() + text.slice(1);
}
