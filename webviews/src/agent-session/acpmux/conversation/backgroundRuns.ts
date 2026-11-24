// A run of background-task notifications folds into one line (Leo, 2026-11-02, on a chat that drew
// "Background task finished" four times, each with a lone "·" reply under it: "why do you still do
// these" and "should we improve the app then"). Two or more of them in a row, with nothing the
// person needs between them, draw as "4 background tasks finished"; a click opens the line to the
// rows exactly as they drew before. A notification the agent answered with something to say is no
// member: acpmux called its turn not quiet, so it has no line and its reply draws as it came.
//
// Members: a quiet background turn's line that has ended (backgroundTurns.ts), and a background
// shell's end noted where it ended (BackgroundTaskNote.tsx), finished, stopped or failed. A failed
// shell joins the run and the line counts it ("21 background commands finished, 2 failed"), so a
// failure is still named in sight. Between members, a reply that draws nothing (visibleMessage.ts: empty or
// a lone period) and the rows of a member line the reader
// opened on its own (`inBackground`) go with the run. Anything else ends it. A line acpmux weighed
// (backgroundTurns.ts `backgroundWeight`: a result its call could not carry, a failure) names its
// own task and is no member either.
//
// The line reuses the background turn's row kind, so it takes that line's height, spacing and look
// everywhere (model.ts, App.tsx); it carries `backgroundRun` instead of `background`. Its open state
// is the transcript's fold set, keyed by its first member, like a message run's line
// (messageRuns.ts). One pass over a turn's rows, beside foldMessageRuns: no work per token beyond the
// turn shaping already does.
//
// Shell ends fold in every look of background turns (backgroundTurnLook.experiment.ts). With the
// default look, where a background turn's calls draw inline, only the shell ends are members: a chat
// with dozens of subagents drew one "Background command completed" row per subagent shell, dozens in
// a row (Leo, 2026-11-12: "Holy crap, there are way too many [waits] here... this looks like a
// degenerate [state], bro"). Now they are one line, "23 background commands finished".
//
// Rows the harness writes into a turn are members too, by what they are (`harnessWork`), never by
// their text: a task-notification line, another session's message Claude Code relayed, acpmux's
// inbox relay, a subagent's "Report from" line (Leo, 2026-11-24: "we can initiate the Worked for with
// these background tasks as actual tool calls. we can indeed treat them as tool calls, even though
// they're bursted at the end/start of turns. thereby we can have them be folded properly too."). A
// burst of them reads as one count, "5 task notifications", or the parts of a mixed one, "3 task
// notifications, 2 messages from agents, 1 background command". A run of messages alone is no
// member run: it stays the turn's "Received N messages" row (laneNoticeBatches.ts).
import type { AcpmuxBackgroundRun, AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { backgroundTurnLook, backgroundTurnsInline } from "./backgroundTurnLook.experiment";
import { BACKGROUND_TURN, backgroundWeight } from "./backgroundTurns";
import { SUBAGENT_DONE } from "../subagents/subagentRows";
import type { Folds } from "./viewFolds";
import { isVisiblyEmptyMessage } from "./visibleMessage";
import { isWaitingMessage } from "./pendingMessages";
import { inboxCounts } from "./inboxNotice";
import { isSubagentReport } from "../subagents/subagentReportLineModel";

export const BACKGROUND_RUN = "backgroundRun";

export const backgroundRunRowId = (firstId: string) => `${BACKGROUND_RUN}-${firstId}`;

type MemberKind = "finished" | "stopped" | "failed" | "scheduled" | "other";

/// What a row the harness wrote into a turn is, when it is one (`harnessWork`).
export type HarnessKind = "notification" | "message" | "report";

/// A row the harness wrote into the turn it arrived in, which is that turn's tool-call work, by what
/// it is: a task notification (an incoming notice, marked `lineOrigin: "task-notification"` or a
/// legacy one known by its envelope), another session's message Claude Code relayed
/// (`lineOrigin: "peer"`), acpmux's inbox relay, or a subagent's "Report from" line once its turn
/// ended. Never a fixed point: the person's own prompt or steer (no `incoming`, RFD 0085), a message
/// `fromPerson`, a tool's fire, one still waiting for the agent, a `received` result, a report whose
/// task failed. A failed subagent's end is no row of this kind (it waits on a Retry).
export function harnessWork(row: AcpmuxRow): HarnessKind | undefined {
  if (row.kind === BACKGROUND_TURN) {
    const turn = row.background;
    return turn &&
      !turn.running &&
      isSubagentReport(row) &&
      turn.cause?.weight !== "failure" &&
      turn.cause?.status !== "failed"
      ? "report"
      : undefined;
  }
  if (row.kind !== "user" || row.received !== undefined || row.pending || row.failed) return undefined;
  const incoming = row.incoming;
  if (incoming?.kind === "notice") return "notification";
  if (incoming?.kind === "inbox") return isWaitingMessage(row) ? undefined : "message";
  if (incoming?.kind !== "message") return undefined;
  const message = incoming.message;
  if (message.lineOrigin !== "peer" || message.fromPerson || message.notice?.severity === "fire") return undefined;
  return isWaitingMessage(row) ? undefined : "message";
}

/// How many messages a harness message row brings: an inbox relay counts its messages.
const messagesIn = (row: AcpmuxRow) =>
  row.incoming?.kind === "inbox" ? Math.max(1, inboxCounts(row.incoming.notice).messages) : 1;

/// What a member adds to its run's line, or undefined for a row that is no member. `inline`: the
/// default look, where background turns draw no line, so only shell ends are members.
function memberKind(row: AcpmuxRow, inline: boolean): MemberKind | undefined {
  if (row.kind === BACKGROUND_TURN) {
    if (inline) return undefined;
    const turn = row.background;
    if (!turn || turn.running || turn.quiet !== true || backgroundWeight(turn)) return undefined;
    if (turn.trigger === "task_notification") return "finished";
    return turn.trigger === "scheduled" ? "scheduled" : "other";
  }
  if (row.kind === SUBAGENT_DONE) {
    // A subagent's end, whatever the harness wrote (acpmux's own lifecycle record, not the text of
    // a notification): it counts as a run's member like a shell's end.
    const state = row.subagents?.[0]?.state;
    if (state === "completed") return "finished";
    if (state === "failed") return "failed";
    return state === "cancelled" || state === "disconnected" ? "stopped" : undefined;
  }
  if (row.kind === "backgroundTask") {
    const state = row.backgroundTask?.state;
    if (state === "completed") return "finished";
    if (state === "stopped") return "stopped";
    if (state === "failed") return "failed";
  }
  return undefined;
}

type SubagentEnd = NonNullable<AcpmuxBackgroundRun["subagentEnd"]>;

/// How a subagent's end row says it ended.
function subagentEnd(row: AcpmuxRow): SubagentEnd {
  const state = row.subagents?.[0]?.state;
  if (state === "failed") return "failed";
  if (state === "disconnected") return "disconnected";
  return state === "cancelled" ? "stopped" : "finished";
}

/// A row of a member line the reader opened (`lines` holds the members' background turn ids): it
/// goes with the run, also after its last member, so closing the run hides it with its line.
const ownedBy = (row: AcpmuxRow, lines: ReadonlySet<string>) =>
  row.inBackground !== undefined && lines.has(row.inBackground);

/// A reply between members that draws nothing goes with the run without counting.
const bareReply = (row: AcpmuxRow) => row.kind === "assistant" && !row.streaming && isVisiblyEmptyMessage(row);

/// `rows` with each run of two or more background-task notifications folded under one line: the
/// line alone while closed, the line and the run's rows while open (`expanded` holds the line's
/// id). Without such a run, `rows` itself. `live`: the rows of a running turn, where a row the
/// harness wrote draws as it came until the turn ends (a running turn folds nothing).
export function foldBackgroundRuns(rows: AcpmuxRow[], expanded: Folds, live = false): AcpmuxRow[] {
  // Inline, a background turn's calls draw as they came, as a tool call's row does
  // (backgroundTurnLook.experiment.ts); a run of shell ends still folds.
  const inline = backgroundTurnsInline(experimentArm(backgroundTurnLook));
  const harness = (row: AcpmuxRow) => (live ? undefined : harnessWork(row));
  const memberOf = (row: AcpmuxRow) => memberKind(row, inline) ?? harness(row);
  let out: AcpmuxRow[] | undefined;
  let index = 0;
  let outerOpen = false;
  while (index < rows.length) {
    const first = rows[index]!;
    if (first.kind === "worked") outerOpen = first.foldOpen === true;
    if (!memberOf(first)) {
      out?.push(first);
      index += 1;
      continue;
    }
    const counts = { finished: 0, stopped: 0, failed: 0, scheduled: 0, other: 0 };
    const harnessCounts = { notifications: 0, messages: 0, reports: 0 };
    let messageRows = 0;
    let commands = 0;
    let subagents = 0;
    const endKinds = new Set<SubagentEnd>();
    const lines = new Set<string>();
    let end = index;
    let last = index;
    for (; end < rows.length; end += 1) {
      const row = rows[end]!;
      const kind = memberKind(row, inline);
      const written = kind ? undefined : harness(row);
      // A failed subagent end waits on Retry in sight (lane/failed-subagents-group): harness rows never
      // join a run with it, so a burst around it does not take it away.
      if (
        (written && counts.failed > 0) ||
        (kind === "failed" && harnessCounts.notifications + harnessCounts.reports + messageRows > 0)
      )
        break;
      if (written) {
        if (written === "notification") harnessCounts.notifications += 1;
        else if (written === "report") harnessCounts.reports += 1;
        else {
          harnessCounts.messages += messagesIn(row);
          messageRows += 1;
        }
        last = end;
      } else if (kind) {
        counts[kind] += 1;
        if (row.kind === "backgroundTask") commands += 1;
        if (row.kind === SUBAGENT_DONE) {
          subagents += 1;
          endKinds.add(subagentEnd(row));
        }
        if (row.background) lines.add(row.background.id);
        last = end;
      } else if (ownedBy(row, lines)) last = end;
      else if (!bareReply(row)) break;
    }
    // Bare replies after the run's last member are not the run's: they draw (nothing) as before.
    end = last + 1;
    const ends = counts.finished + counts.stopped + counts.failed + counts.scheduled + counts.other;
    const written = harnessCounts.notifications + harnessCounts.reports + messageRows;
    const members = ends + written;
    // Other agents' messages alone stay the turn's "Received N messages" row (laneNoticeBatches.ts).
    if (members < 2 || members === messageRows) {
      out?.push(...rows.slice(index, end));
      index = end;
      continue;
    }
    out ??= rows.slice(0, index);
    const folded = rows.slice(index, end);
    // Open under any member's key, as a message run is (messageRuns.ts): two runs a reply that draws
    // nothing joins, or a run whose first member changed, keep the open the reader gave one of them.
    // Its id is that key, so a click closes it by the same key. Keyed lookups, one per member.
    const opened = folded.find((row) => expanded.has(backgroundRunRowId(row.id)));
    const id = backgroundRunRowId((opened ?? first).id);
    const open = opened !== undefined || outerOpen;
    const run: AcpmuxBackgroundRun = {
      ...counts,
      commands,
      ...(subagents > 0 && { subagents, ...(endKinds.size === 1 && { subagentEnd: [...endKinds][0] }) }),
      ...(harnessCounts.notifications > 0 && { notifications: harnessCounts.notifications }),
      ...(harnessCounts.messages > 0 && { messages: harnessCounts.messages }),
      ...(harnessCounts.reports > 0 && { reports: harnessCounts.reports }),
      rows: folded.map((row) => row.id),
    };
    out.push({
      id,
      // Moves with every member's version and the open state: the memoized line and the height
      // cache compare versions only.
      version: folded.reduce((sum, row) => (sum * 31 + row.version) % 1_000_003, folded.length) * 2 + (open ? 1 : 0),
      at: first.at,
      kind: BACKGROUND_TURN,
      foldOpen: open,
      backgroundRun: run,
    });
    if (open) out.push(...folded);
    index = end;
  }
  return out ?? rows;
}

/// The open background-run lines among a turn's rows `rows[start..end)`, which a cached turn
/// compares. A line's id is the member's it was opened under (`foldBackgroundRuns`).
export function openBackgroundRuns(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  let open = "";
  for (let at = start; at < end; at += 1) {
    const id = backgroundRunRowId(rows[at]!.id);
    if (expanded.has(id)) open += `${id} `;
  }
  return open;
}

/// The closed background-run line among `drawn` that folds the row `rowId` away, so Find or a link
/// opens it.
export function backgroundRunFoldFor(drawn: readonly AcpmuxRow[], rowId: string): string | undefined {
  for (const row of drawn)
    if (row.backgroundRun && !row.foldOpen && row.backgroundRun.rows.includes(rowId)) return row.id;
  return undefined;
}

/// The line's words. A run of completed shell ends only says "23 background commands completed".
/// A stopped one uses the broader "finished" wording, while failures retain their count:
/// "21 background commands completed, 2 failed" or "2 background commands failed".
/// Else "4 background tasks finished" when every member finished, else "5 background updates" (a
/// stopped shell, a scheduled check or another kind of background turn among them), with the failed
/// count after it when one failed.
export function backgroundRunLabel(t: Translate, run: AcpmuxBackgroundRun): string {
  if (run.notifications || run.messages || run.reports) return harnessRunLabel(t, run);
  const failed = run.failed;
  const n = run.finished + run.stopped + failed + run.scheduled + run.other;
  const ended = n - failed;
  // Subagents' ends alone: "12 subagents stopped", the one way they all ended, else "12 subagents ended".
  if (run.subagents === n) {
    if (run.subagentEnd === "stopped") return t("backgroundRun.subagentsStopped", { n });
    if (run.subagentEnd === "disconnected") return t("backgroundRun.subagentsDisconnected", { n });
    if (run.subagentEnd === "failed") return t("backgroundRun.subagentsFailed", { n });
    if (run.subagentEnd === "finished") return t("backgroundRun.subagentsFinished", { n });
    return t("backgroundRun.subagentsEnded", { n });
  }
  if (run.commands === n) {
    if (ended === 0) return t("backgroundRun.commandsAllFailed", { n: failed });
    if (run.stopped === 0) {
      if (failed === 0) return t("backgroundRun.commandsCompleted", { n });
      return t("backgroundRun.commandsCompletedFailed", { n: ended, failed });
    }
    if (failed === 0) return t("backgroundRun.commands", { n });
    return t("backgroundRun.commandsFailed", { n: ended, failed });
  }
  const words = n === run.finished ? t("backgroundRun.finished", { n }) : t("backgroundRun.updates", { n });
  return failed ? `${words}, ${t("backgroundRun.failedCount", { n: failed })}` : words;
}

/// Each part's words for one member and for `{n}` of them.
const PARTS = {
  notifications: ["backgroundRun.part.notifications.one", "backgroundRun.part.notifications.other"],
  reports: ["backgroundRun.part.reports.one", "backgroundRun.part.reports.other"],
  messages: ["backgroundRun.part.messages.one", "backgroundRun.part.messages.other"],
  subagents: ["backgroundRun.part.subagents.one", "backgroundRun.part.subagents.other"],
  commands: ["backgroundRun.part.commands.one", "backgroundRun.part.commands.other"],
  updates: ["backgroundRun.part.updates.one", "backgroundRun.part.updates.other"],
} as const;

/// The line of a run that holds rows the harness wrote (`harnessWork`): each kind's count in the
/// order a turn's work reads, "5 task notifications" alone, "3 task notifications, 2 messages from
/// agents, 1 background command" mixed, with the failed count after it when one failed.
function harnessRunLabel(t: Translate, run: AcpmuxBackgroundRun): string {
  const part = (key: keyof typeof PARTS, n: number) => (n === 1 ? t(PARTS[key][0]) : t(PARTS[key][1], { n }));
  const subagents = run.subagents ?? 0;
  const ends = run.finished + run.stopped + run.failed + run.scheduled + run.other;
  const updates = ends - subagents - run.commands;
  const parts = [
    ...(run.notifications ? [part("notifications", run.notifications)] : []),
    ...(run.reports ? [part("reports", run.reports)] : []),
    ...(run.messages ? [part("messages", run.messages)] : []),
    ...(subagents ? [part("subagents", subagents)] : []),
    ...(run.commands ? [part("commands", run.commands)] : []),
    ...(updates > 0 ? [part("updates", updates)] : []),
  ];
  const words = parts.join(", ");
  return run.failed ? `${words}, ${t("backgroundRun.failedCount", { n: run.failed })}` : words;
}
