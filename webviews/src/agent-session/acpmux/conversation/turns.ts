// A turn in the transcript: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After the reference prototype's
// derive.ts (`deriveTurn`, `formatDuration`).
//
// Stop-gap seam: acpmux owns the turn structure (spec acp-ui.md, OWNERSHIP-PRINCIPLES.md). When
// acpmux serves turn-structured rows (`acp.view.subscribe`, `_acpmux/view`), `turnView` becomes
// a field-for-field mapping of them and nothing else in the pane changes.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { continuesTurn, opensTurn } from "../turnStart";
import { findRowIndex } from "./chatFind";
import { turnPreviewCardsOn, turnPreviewUrl } from "./previewUrl";
import { renderCall } from "./renderCall";
import { showsTimestamp, type TurnTimes } from "./timestamps";
import { isSubagentGroup, WORKFLOW_CARD } from "../subagents/subagentRows";
import { STARTED_SESSIONS } from "../started/startedSessions";
import { QUESTION_RECORD } from "../question/record";
import type { Translate } from "../i18n";
import { editedPaths, isBareShellName, toolLabel } from "../toolPaths";
import { shortCommand } from "./shortCommand";
import { tailStart } from "./ToolGroupRow";
import { awaitsPermission, isDraftCall, isRunning, toolGroups } from "./toolGroups";
import { acpmuxSendCall } from "./acpmuxSends";
import { subsessionCall } from "./subsessionCalls";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
/// A row added by this pass: the timestamp line over a turn (timestamps.ts).
export const DATE = "date";
/// Rows added for the turn still running: "Thinking" until it has output, then a ticking
/// "Working for 42s" line over its work, where "Worked for" lands when the turn ends.
export const THINKING = "thinking";
/// The last turn's Thinking line has one id from send to the first output: the sent prompt's row
/// changes id when acpmux echoes it, the line keeps its place (cx-ncc.58).
const LIVE_THINKING = `${THINKING}-live`;
export const WORKING = "working";
/// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
/// cx-ncc.102): what the agent is doing now and how long the turn has run.
export const ACTIVITY_LINE = "activityLine";
/// A row added for an ended turn that started or mentioned a local web page (previewUrl.ts): its
/// preview card, with the page's address as its text. Only with the Debug toggle
/// `agentPane.debug.turnPreviewCards` (`turnPreviewCardsOn`).
export const PREVIEW = "preview";
/// A row added for each render call of an ended turn (renderCall.ts), above its answer: the
/// render card, with the call as its one item.
export const RENDER = "render";
/// Activity rows shown inside an open disclosure are copies under this suffix, so the
/// edited-files card after the answer keeps the original id.
const FOLDED = ":fold";

/// "1m 16s", "42s", "1h 3m"; zero units dropped, under one second is "0s".
export function formatDuration(ms: number): string {
  const total = Math.floor(ms / 1000);
  if (total <= 0) return "0s";
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join(" ");
}

export const toolCalls = (t: Translate, count = 0) => t("turn.toolCalls", { n: count });

/// The disclosure's label: "Worked for 1m 16s", "You stopped after 40s",
/// or "34 previous messages" for a row that carries a count instead of timing (turns without a
/// summary no longer fold, so none does today). It shows no tool-call count.
export function workedLabel(t: Translate, row: AcpmuxRow): string {
  if (row.previous !== undefined)
    return row.previous === 1 ? t("turn.previous.one") : t("turn.previous.other", { n: row.previous });
  if (row.durationMs === undefined) return toolCalls(t, row.toolCount);
  const time = formatDuration(row.durationMs);
  return row.status === "cancelled" ? t("turn.stopped", { time }) : t("turn.worked", { time });
}

/// A turn summary for a turn that was stopped (Stop, Esc, or an interruption) and did not go on
/// under a prompt sent now (`continued`).
export const isStopped = (row: AcpmuxRow) =>
  row.kind === "turnSummary" && (row.status === "cancelled" || row.status === "interrupted") && !row.continued;

/// What a turn's footer says before its buttons, or nothing: a turn whose work folds under "Worked
/// for" says it there, and a turn under a second says nothing, since "Worked for 0s" is no news
/// (Leo, 2026-10-21: "IF WE 0 SECONDS THEN IT DOESNT NEED TO TAKE UP SPACE"). A stopped turn still
/// says it stopped, and a footer without timing (history paged in mid-turn) its count.
export function footerLabel(t: Translate, row: AcpmuxRow): string | undefined {
  return footerSays(row) ? workedLabel(t, row) : undefined;
}
const footerSays = (row: AcpmuxRow) =>
  !row.folded &&
  (row.previous !== undefined || row.durationMs === undefined || row.durationMs >= 1000 || row.status === "cancelled");

/// A footer with nothing to show at rest and only hover controls (Pin, Fork, its age): no label, no
/// answer to copy or read aloud, the turn did not fail, and it offers no Continue (a stopped last
/// turn whose work folds draws its line for Continue alone). It takes no line in the transcript
/// (conversation.css `.cv-turn-actions--empty`, model.ts fallbackRowHeight); pointed at, its controls
/// show over the turn gap below, so nothing moves.
export const isEmptyFooter = (row: AcpmuxRow) =>
  row.kind === "turnSummary" &&
  row.status !== "failed" &&
  row.status !== "error" &&
  !row.text &&
  !row.resumable &&
  !footerSays(row);

const isEditTool = (tool: { kind?: string } | undefined) => tool?.kind === "edit" || tool?.kind === "fileChange";
const isEdit = (row: AcpmuxRow) => row.kind === "activity" && (row.items ?? []).some((item) => isEditTool(item.tool));

/// The rows to draw. `expanded` holds the ids of open disclosures; `working` says the last
/// turn is still running (the snapshot's `isWorking`); `now` dates the turns (timestamps.ts);
/// `clockOffset` (the snapshot's `clockOffsetMs`) moves the running turn's start onto this
/// computer's clock, so its "Working for" counts from the prompt. `sessionStatus` (the Debug
/// toggle `agent.sessionStatus`) puts a running turn's todo list under its work, with the
/// activity line under it.
export function turnView(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  options: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    liveRuns?: boolean;
    sessionStatus?: boolean;
    lineBelow?: boolean;
  } = {},
): AcpmuxRow[] {
  return turnViewFrom(rows, expanded, options).rows;
}

/// A turn view (``turnViewFrom``) with what it was drawn from, for the next snapshot to build on.
export type TurnView = {
  source: readonly AcpmuxRow[];
  expanded: ReadonlySet<string>;
  clockOffset: number;
  liveRuns: boolean;
  lineBelow: boolean;
  working: boolean;
  sessionStatus: boolean;
  /// Where the first prompt is: the rows before it draw as they are.
  lead: number;
  /// Each turn's prompt index in `source`, its times, whether it is dated, and how many drawn
  /// rows there are up to its end.
  starts: number[];
  times: TurnTimes[];
  dated: boolean[];
  ends: number[];
  rows: AcpmuxRow[];
};

/// ``turnView``, building on `previous`: the turns before the one holding the first row that
/// differs from `previous.source` (by object) keep their drawn rows, so a long chat's snapshot
/// shapes only its last turns.
export function turnViewFrom(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  {
    now = Date.now(),
    working = false,
    clockOffset = 0,
    liveRuns = false,
    sessionStatus = false,
    lineBelow = false,
  }: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    liveRuns?: boolean;
    sessionStatus?: boolean;
    lineBelow?: boolean;
  } = {},
  previous?: TurnView,
): TurnView {
  if (
    previous &&
    previous.source === rows &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.liveRuns === liveRuns &&
    previous.lineBelow === lineBelow &&
    previous.working === working &&
    previous.sessionStatus === sessionStatus &&
    (!previous.starts.length ||
      showsTimestamp(previous.times[0]!, undefined, now, previous.lead === 0) === previous.dated[0])
  )
    return previous;
  // The turn to shape from: the one holding the first changed row. The turn before it may
  // have ended there, and the last turn draws differently once another follows it.
  let reuse = 0;
  if (
    previous &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.liveRuns === liveRuns &&
    previous.lineBelow === lineBelow &&
    previous.starts.length
  ) {
    const shared = previous.source;
    if (rows === shared) reuse = previous.starts.length;
    else {
      let from = 0;
      while (from < rows.length && from < shared.length && rows[from] === shared[from]) from += 1;
      while (reuse < previous.starts.length && previous.starts[reuse]! < from) reuse += 1;
    }
    reuse = Math.max(0, reuse - 1);
  }
  // The first turn's line depends on `now`.
  if (reuse > 0 && showsTimestamp(previous!.times[0]!, undefined, now, previous!.lead === 0) !== previous!.dated[0])
    reuse = 0;
  let index: number;
  let lead: number;
  let out: AcpmuxRow[];
  let starts: number[];
  let times: TurnTimes[];
  let dated: boolean[];
  let ends: number[];
  if (reuse > 0) {
    lead = previous!.lead;
    index = previous!.starts[reuse]!;
    out = previous!.rows.slice(0, previous!.ends[reuse - 1]);
    starts = previous!.starts.slice(0, reuse);
    times = previous!.times.slice(0, reuse);
    dated = previous!.dated.slice(0, reuse);
    ends = previous!.ends.slice(0, reuse);
  } else {
    out = [];
    index = 0;
    // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are.
    while (index < rows.length && rows[index]!.kind !== "user") out.push(rows[index++]!);
    lead = index;
    starts = [];
    times = [];
    dated = [];
    ends = [];
  }
  const first = starts.length;
  const fromStart = lead === 0;
  // Each turn is its prompt's index up to the next accepted prompt: its rows, and any prompt not
  // yet accepted (sent while this turn runs, or refused), which sorts among them by its send time
  // and neither ends the turn nor folds into it. A steer goes on with the turn it went into
  // (``continuesTurn``). Indexes, not arrays: a long chat's snapshot only copies the rows of a
  // turn that changed (shapedTurn).
  while (index < rows.length) {
    const start = index++;
    let answerAt: number | undefined;
    while (
      index < rows.length &&
      (rows[index]!.kind !== "user" || isUnsent(rows[index]!) || continuesTurn(rows[index]!))
    ) {
      if (isAnswer(rows[index]!)) answerAt = rows[index]!.at;
      index += 1;
    }
    starts.push(start);
    const turn = { promptAt: rows[start]!.at, answerAt };
    dated.push(showsTimestamp(turn, times.at(-1), now, fromStart));
    times.push(turn);
  }
  for (let at = first; at < starts.length; at += 1) {
    const start = starts[at]!;
    const end = at + 1 < starts.length ? starts[at + 1]! : rows.length;
    // Only the last turn can still be running.
    const last = at === starts.length - 1;
    const live = working && last;
    for (const row of shapedTurn(
      rows,
      start,
      end,
      expanded,
      live,
      last,
      clockOffset,
      dated[at]!,
      liveRuns,
      sessionStatus,
      lineBelow,
    ))
      out.push(row);
    ends.push(out.length);
  }
  return {
    source: rows,
    expanded,
    clockOffset,
    liveRuns,
    lineBelow,
    working,
    sessionStatus,
    lead,
    starts,
    times,
    dated,
    ends,
    rows: out,
  };
}

/// A turn as drawn, kept while its rows (by identity) and what shapes them stay the same: a long
/// chat's snapshot rebuilds only the turns that changed, and an unchanged turn's derived rows stay
/// the same objects, so the row memos and the height cache keep them.
type ShapedTurn = {
  /// The turn's rows after its prompt, held prompts included, as last shaped.
  source: readonly AcpmuxRow[];
  /// Which of its folds are open (`openFolds`).
  open: string;
  last: boolean;
  clockOffset: number;
  dated: boolean;
  liveRuns: boolean;
  rows: AcpmuxRow[];
};
const shapedTurns = new WeakMap<AcpmuxRow, ShapedTurn>();

/// Which of the turn at `rows[start]` up to `end` has its "Worked for" open: the prompt's, each
/// steer's (`turnParts`) and each takeaway's (`foldSegments`), as a key ("" when none is).
function openFolds(rows: readonly AcpmuxRow[], start: number, end: number, expanded: ReadonlySet<string>): string {
  if (expanded.size === 0) return "";
  let key = expanded.has(`${WORKED}-${rows[start]!.id}`) ? "1" : "0";
  // A takeaway keys the fold after it (foldSegments).
  for (let index = start + 1; index < end; index += 1)
    if (continuesTurn(rows[index]!) || rows[index]!.kind === "assistant")
      key += expanded.has(`${WORKED}-${rows[index]!.id}`) ? "1" : "0";
  return key.includes("1") ? key : "";
}

/// The drawn rows of the turn at `rows[start]` (its prompt) up to `end`, then its held prompts.
function shapedTurn(
  rows: readonly AcpmuxRow[],
  start: number,
  end: number,
  expanded: ReadonlySet<string>,
  live: boolean,
  last: boolean,
  clockOffset: number,
  dated: boolean,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
): AcpmuxRow[] {
  const user = rows[start]!;
  const open = openFolds(rows, start, end, expanded);
  // A running turn changes with every event.
  const cached = live ? undefined : shapedTurns.get(user);
  if (
    cached &&
    cached.open === open &&
    cached.last === last &&
    cached.clockOffset === clockOffset &&
    cached.dated === dated &&
    cached.liveRuns === liveRuns &&
    cached.source.length === end - start - 1
  ) {
    let same = true;
    for (let index = start + 1; same && index < end; index += 1)
      same = cached.source[index - start - 1] === rows[index];
    if (same) return cached.rows;
  }
  const source = rows.slice(start + 1, end);
  // A steer draws where it went into the turn; bookkeeping sent in draws nothing
  // (incomingMessage.ts). The summary of the turn a prompt sent now stopped is not a Stop: the
  // turn goes on under that prompt, so it neither ends nor times the turn.
  // Nor does it before the steer's own record comes, while it is the turn's last summary: the turn
  // is about to go on, and would read "You stopped after" for that moment.
  const turn = source.filter(
    (row, at) =>
      (row.kind !== "user" || (continuesTurn(row) && row.incoming?.kind !== "hidden")) &&
      !(
        row.kind === "turnSummary" &&
        row.continued &&
        (source.slice(at + 1).some(continuesTurn) ||
          (last && !source.slice(at + 1).some((later) => later.kind === "turnSummary")))
      ),
  );
  const held = source.filter((row) => row.kind === "user" && !continuesTurn(row));
  const date = dated ? [{ id: `${DATE}-${user.id}`, version: 1, at: user.at, kind: DATE }] : [];
  // A sent prompt waiting for its turn to open draws the Thinking line already, with the start
  // status while its agent starts (harnessSwitch: "Starting Claude Code…"); the line never
  // jumps from under the bubble to the turn's status row, nor leaves for a frame (cx-ncc.58).
  const waiting = !live && last && user.pending && !user.failed && turn.length === 0 && held.length === 0;
  let shaped: AcpmuxRow[];
  if (waiting) {
    const { status, queued } = user;
    const line: AcpmuxRow = { id: LIVE_THINKING, version: status ? 0 : 1, at: user.at, kind: THINKING };
    if (status) Object.assign(line, { status, queued });
    shaped = [...date, status ? { ...user, status: undefined } : user, line];
  } else {
    const body = shapeTurn(
      user,
      turn,
      expanded,
      live,
      last,
      last && held.length === 0,
      clockOffset,
      liveRuns,
      sessionStatus,
      lineBelow,
    );
    // A running turn's line drawn below stays its last row, under the prompts it holds (a steer
    // waiting for the agent, a prompt that failed to send).
    const line = held.length && body.at(-1)?.below ? body.splice(-1) : [];
    shaped = [
      ...date,
      // Bookkeeping alone starts a turn but draws nothing (incomingMessage.ts).
      ...(user.incoming?.kind === "hidden" ? [] : [user]),
      ...body,
      ...held,
      ...line,
    ];
    // Legacy/history turns can end without a turn_result. Keep the normal turn rhythm at the
    // composer for the latest completed turn without restoring the permanent runway under every
    // turn. The marker is consumed by the row estimator and CSS only for this terminal row.
    if (last && !live && held.length === 0 && !turn.some((row) => row.kind === "turnSummary")) {
      let final = shaped.length - 1;
      while (final >= 0 && (shaped[final]!.kind === DATE || shaped[final]!.kind === "user")) final -= 1;
      if (final >= 0) shaped[final] = { ...shaped[final]!, lastTurn: true };
    }
  }
  if (!live) shapedTurns.set(user, { source, open, last, clockOffset, dated, liveRuns, rows: shaped });
  return shaped;
}

const isAnswer = (row: AcpmuxRow) => row.kind === "assistant";

/// A tool call after a turn's last text: the turn ended on work, so that text was its narration.
/// Edits join the turn's card and render calls draw as their own cards, so neither counts; a
/// step that edited and then ran something does.
const isWork = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool && !isEditTool(item.tool) && !renderCall(item.tool));

/// Where a finished turn's answer is in `rows`: its last takeaway (``takeawaysIn``). -1: none, so
/// all of it folds, as the Codex and Claude desktop apps fold it.
function answerAt(rows: readonly AcpmuxRow[]): number {
  const kept = takeawaysIn(rows);
  for (let at = rows.length - 1; at >= 0; at -= 1) if (kept.has(rows[at]!)) return at;
  return -1;
}

/// A reply with something to read: an empty segment of the agent's text is never a takeaway.
const isReply = (row: AcpmuxRow) => isAnswer(row) && (row.text ?? "").trim().length > 0;

/// The one rule for what of a finished turn stays in sight (Leo, 2026-10-21: "we dont want end of
/// turn takeaway responses to be folded in im pretty sure..."; "is there a true final takeaway that
/// we can keep?"): a reply that reads as a takeaway, substantive prose addressed to the person
/// (``isTakeaway``), wherever it is in the turn, and the turn's final reply, the text after its last
/// step ("Pushed."). Everything else (tool rows, thoughts, compactions, where a subagent ended,
/// short narration such as "Let me check…") is work and folds.
function takeawaysIn(rows: readonly AcpmuxRow[]): Set<AcpmuxRow> {
  const kept = new Set<AcpmuxRow>();
  let stepped = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (isReply(row) && (isTakeaway(row) || (!stepped && kept.size === 0))) kept.add(row);
    if (isWork(row)) stepped = true;
  }
  return kept;
}

/// A stretch of a finished part: the work since `anchor` (the part's prompt or steer, or the
/// takeaway before it), then the takeaway it led to. The part's last stretch may have no takeaway
/// (it ended on work); `after` is the work that came after the part's last takeaway, which folds
/// with the stretch before it so the takeaway stays the part's last words (#23843).
export type FoldSegment = { anchor: AcpmuxRow; rows: AcpmuxRow[]; takeaway?: AcpmuxRow; after?: AcpmuxRow[] };

/// A finished part's rows (after its prompt or steer, `opener`) in stretches: each takeaway stays
/// in sight and the work between two takeaways folds on its own between them, under a "Worked for"
/// keyed by the row before it (`worked-<anchor id>`). So a turn reads [fold][takeaway][fold]
/// [takeaway], never one fold over the lot. shapeTurn draws it and turnFoldFor finds a row's fold
/// with it, so Find opens the fold that holds the row.
export function foldSegments(opener: AcpmuxRow, rows: readonly AcpmuxRow[]): FoldSegment[] {
  const drawn = rows.filter((row) => row.kind !== "typing");
  const kept = takeawaysIn(drawn);
  const segments: FoldSegment[] = [];
  let anchor = opener;
  let stretch: AcpmuxRow[] = [];
  for (const row of drawn) {
    if (!kept.has(row)) {
      stretch.push(row);
      continue;
    }
    segments.push({ anchor, rows: stretch, takeaway: row });
    anchor = row;
    stretch = [];
  }
  const last = segments.at(-1);
  if (stretch.length && last) last.after = stretch;
  else if (stretch.length || !last) segments.push({ anchor, rows: stretch });
  return segments;
}

const isUnsent = (row: AcpmuxRow) => Boolean(row.pending || row.failed);

function shapeTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  expanded: ReadonlySet<string>,
  live: boolean,
  last: boolean,
  retryable: boolean,
  clockOffset = 0,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens, under its live status; one without a
  // summary that is no longer running draws as it came.
  if (end < 0)
    return live
      ? liveTurn(user, turn, clockOffset, liveRuns, sessionStatus, lineBelow)
      : last
        ? turn.flatMap(withoutDrafts).map(endedPlan)
        : settledWithoutSummary(turn);
  const summary = turn[end]!;
  const body = turn.slice(0, end);
  const final = answerAt(body);
  const answer = final >= 0 ? body[final] : undefined;
  const shaped: AcpmuxRow[] = [];
  // A derived row's version must change whenever what it draws does: the memoized rows and the
  // height cache compare versions only. Answer versions stay far below VERSION_SPAN.
  const version = summary.version * VERSION_SPAN + (answer?.version ?? 0);
  const edits: AcpmuxRow[] = [];
  let folded = false;
  // Each part of the turn (its prompt's, then each steer's) folds its own work under its own
  // "Worked for", as Codex draws a steered turn: the work after a steer folds below the steer,
  // where it ran, never up above it into the first part's fold. Within a part each takeaway stays
  // in sight and the work before it folds on its own (foldSegments).
  for (const part of turnParts(user, body)) {
    if (part.opener !== user) shaped.push(part.opener);
    const lastPart = part.until === undefined;
    // The last "Worked for" of the turn's last part ended as the turn did ("You stopped after"),
    // whichever stretch it folds (a stretch with no work draws none).
    let lastWorked: AcpmuxRow | undefined;
    for (const segment of foldSegments(part.opener, part.rows)) {
      const said = segment.takeaway;
      const before = segment.rows;
      const after = segment.after ?? [];
      // Work after the part's last takeaway (a tool the agent ran once it had replied, and its
      // interim notes) folds with the work before it, so the takeaway stays the part's last words.
      // Edits after it join the card too, so its Undo covers the whole turn.
      const later = after.filter((row) => !isEdit(row) && !staysOut(row));
      const work = [...before.filter((row) => !staysOut(row)), ...later];
      edits.push(...work.filter(isEdit), ...after.filter(isEdit));
      if (work.length) {
        folded = true;
        const id = `${WORKED}-${segment.anchor.id}`;
        const open = expanded.has(id);
        const from = segment.anchor.at;
        const worked: AcpmuxRow = {
          id,
          version: version * 2 + (open ? 1 : 0),
          at: from,
          kind: WORKED,
          toolCount: summary.toolCount,
          durationMs:
            said && !later.length
              ? Math.max(0, said.at - from)
              : !lastPart
                ? Math.max(0, part.until! - from)
                : segment.anchor === user
                  ? (summary.durationMs ?? Math.max(0, summary.at - user.at))
                  : Math.max(0, summary.at - from),
        };
        shaped.push(worked);
        if (lastPart) lastWorked = worked;
        // Open, each run of its work folds into its summary line between the commentary, as in a
        // running turn (codexRuns). A run that edited folds too: its edits stay in sight between the
        // summary lines of the work around them (TurnRows.tsx `runStretches`).
        if (open)
          shaped.push(
            ...(liveRuns ? mergeShortNotes(work) : work).flatMap(withoutDrafts).map((row) => ({
              ...row,
              id: isEdit(row) ? `${row.id}${FOLDED}` : row.id,
              settled: true,
              // A folded run draws otherwise, so its version moves (memos compare versions).
              ...(liveRuns && row.kind === "activity" && { foldRun: true, version: row.version * RUN_STATES + 3 }),
            })),
          );
      }
      shaped.push(...before.filter(staysOut).map(endedPlan), ...renderRows([...before, ...after], version));
      if (said) shaped.push(said);
      shaped.push(...after.filter((row) => !isEdit(row) && !later.includes(row)).map(endedPlan));
    }
    if (lastWorked) lastWorked.status = summary.status;
  }
  shaped.push(...editsCard(edits));
  const preview = turnPreviewCardsOn() ? turnPreviewUrl(user, turn) : undefined;
  if (preview) shaped.push({ id: `${PREVIEW}-${user.id}`, version, at: summary.at, kind: PREVIEW, text: preview });
  // The footer copies the answer, so it carries the answer's text; the last turn's also retries
  // its prompt, and stops offering to once a later prompt goes (or waits to). A last turn the
  // reader stopped also offers Continue, as Codex does, until a prompt follows it or it runs again.
  // After a turn the agent started on its own (a later summary in its tail), that turn's summary is
  // the one that offers it, when the reader stopped that one.
  let lastSummary = -1;
  for (let at = turn.length - 1; at > end && lastSummary < 0; at -= 1)
    if (turn[at]!.kind === "turnSummary") lastSummary = at - end - 1;
  const offers = retryable && !live;
  const resumable = offers && lastSummary < 0 && isStopped(summary);
  shaped.push({
    ...summary,
    folded,
    text: answer?.text ?? summary.text,
    ...(resumable && { resumable }),
    ...(retryable && { retryable }),
    ...(answer && { answerId: answer.id }),
    // Retry sends the prompt as the agent got it: an incoming message with its sender. A
    // notification is the harness's, not a prompt to send again (incomingMessage.ts).
    ...(retryable &&
      user.incoming?.kind !== "notice" &&
      (user.resend ?? user.text) && {
        prompt: user.resend ?? user.text,
        retryRowId: user.id,
        retryAttachments: user.retryAttachments,
      }),
    version: version * 4 + (retryable ? 1 : 0) + (resumable ? 2 : 0),
  });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  // A turn the agent started on its own while still working keeps its plan live. Once it runs tools
  // the Codex layout draws it as a running turn (a task notification's work, Leo 2026-10-21: four
  // bare command rows stacked under "Worked for 1s"): its finished runs folded, the call in
  // flight on the one live line under them, timed from the summary.
  const tail = turn.slice(end + 1);
  // Its version moves past any acpmux gives the row (VERSION_SPAN), so the memoized footer redraws.
  if (offers && lastSummary >= 0 && isStopped(tail[lastSummary]!)) {
    const stopped = tail[lastSummary]!;
    tail[lastSummary] = { ...stopped, resumable: true, version: stopped.version + VERSION_SPAN };
  }
  if (live && liveRuns && lineBelow && tail.some((row) => row.kind === "activity"))
    shaped.push(...liveTurn(summary, tail, clockOffset, liveRuns, sessionStatus, lineBelow));
  else shaped.push(...(live ? tail : tail.flatMap(withoutDrafts).map(endedPlan)));
  return shaped;
}

const VERSION_SPAN = 1_000_000;

/// A finished turn's rows in parts: what came after its prompt, then after each steer, which
/// opens the part it went into (`until`: when the next steer came, on all but the last part).
function turnParts(
  user: AcpmuxRow,
  body: readonly AcpmuxRow[],
): { opener: AcpmuxRow; rows: AcpmuxRow[]; until?: number }[] {
  const parts: { opener: AcpmuxRow; rows: AcpmuxRow[]; until?: number }[] = [{ opener: user, rows: [] }];
  for (const row of body) {
    if (continuesTurn(row)) {
      parts.at(-1)!.until = row.at;
      parts.push({ opener: row, rows: [] });
    } else parts.at(-1)!.rows.push(row);
  }
  return parts;
}

/// One render card per render call in `body`, in call order.
function renderRows(body: readonly AcpmuxRow[], version: number): AcpmuxRow[] {
  return body.flatMap((row) =>
    row.kind === "activity"
      ? (row.items ?? []).flatMap((item, index) =>
          item.tool && renderCall(item.tool)
            ? [
                {
                  id: `${RENDER}-${item.tool.id || `${row.id}-${index}`}`,
                  version,
                  at: row.at,
                  kind: RENDER,
                  items: [item],
                },
              ]
            : [],
        )
      : [],
  );
}

/// One edited-files card per ended turn: the turn's edit rows merged into the first one (its id,
/// so View changes still finds the turn), every edit's items in order. It is `ended`, so it
/// offers Undo; its version is odd, so the card the turn's live edit row became redraws.
function editsCard(edits: AcpmuxRow[]): AcpmuxRow[] {
  if (edits.length === 0) return [];
  const [first] = edits as [AcpmuxRow, ...AcpmuxRow[]];
  return [
    {
      ...first,
      version: edits.reduce((sum, row) => sum + row.version, 0) * 2 + 1,
      items: edits.flatMap((row) => row.items ?? []),
      toolCount: edits.reduce((sum, row) => sum + (row.toolCount ?? 0), 0),
      ended: true,
      merged: edits.map((row) => row.id),
    },
  ];
}

/// A row that draws under a finished turn's fold line rather than inside it: a subagent group,
/// the turn's todo list (cx-ncc.80), whose last state is what the turn got done, and the notes
/// below. Where a subagent ended and a compaction are the turn's work and fold with it (Leo,
/// 2026-10-21: fold only the work, "compaction and subagent/system notices" among it).
const staysOut = (row: AcpmuxRow) =>
  isSubagentGroup(row) ||
  (row.kind === "plan" && row.plan !== undefined) ||
  row.kind === "backgroundTask" ||
  // An error or a refusal the pane noted, and an ask still waiting on the person.
  row.kind === "notice" ||
  row.kind === "permission" ||
  // A move to the fallback harness changes who answers the rest of the turn; folded, nobody would
  // see it happened.
  row.kind === "failover" ||
  // A policy the harness cannot keep: the agent runs without the asks the person chose.
  row.kind === "policyUnenforced" ||
  // A paused agent pair waits for the person's Resume.
  row.kind === "agentPair" ||
  // Where the session started: what it runs on.
  row.kind === "sessionStart" ||
  // A session offer waits for the person's Start or Dismiss.
  row.kind === "sessionOffer" ||
  // A chat the turn started keeps its card in sight (started/startedSessions.ts).
  row.kind === STARTED_SESSIONS ||
  // So does a Claude workflow it started (Labs, summary/WorkflowCard.tsx).
  row.kind === WORKFLOW_CARD ||
  // What the person answered an agent's question, which shaped the rest of the turn.
  row.kind === QUESTION_RECORD;

/// A finished turn's todo list: a step the agent left in progress no longer spins. The version
/// moves off the live one (v to 2v + 1), so the memoized row draws again when the turn ends.
const endedPlan = (row: AcpmuxRow): AcpmuxRow =>
  row.kind === "plan" && row.plan ? { ...row, turnEnded: true, version: row.version * 2 + 1 } : row;

/// A turn that ended without a summary: a later prompt came before it (another agent's message
/// that arrived while it ran splits it here) or it is history from before acpmux kept summaries.
/// It draws as it came: the agent's messages stay in place, each on its own, and nothing folds
/// that the person did not fold (Leo, 2026-10-20: never auto-collapse messages into "N previous
/// messages").
/// Its edits still close it as one card, which offers Undo.
function settledWithoutSummary(turn: AcpmuxRow[]): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  return [
    ...rows
      .filter((row) => !isEdit(row))
      .flatMap(withoutDrafts)
      .map(endedPlan),
    ...editsCard(rows.filter(isEdit)),
  ];
}

/// An activity row without the calls it has nothing to show for yet (toolGroups.ts `isDraftCall`),
/// or no row when they were all it held, so bare "Running a command" rows never stack up (Leo,
/// 2026-10-21: they should replace each other, as Thinking does). A running turn's live line names
/// the newest (codexLiveTurn); an ended turn's never got their input. Which calls it drops follows
/// from the row's items, so its version stands.
function withoutDrafts(row: AcpmuxRow): AcpmuxRow[] {
  if (row.kind !== "activity") return [row];
  const items = row.items ?? [];
  const kept = items.filter((item) => !(item.tool && isDraftCall(item.tool)));
  if (kept.length === items.length) return [row];
  return kept.length ? [{ ...row, items: kept }] : [];
}

/// The live status. With `lineBelow` (the default in the app, Debug Settings
/// `agentPane.debug.liveLineBelow`) it is the turn's last row from send to end, as Claude desktop
/// draws it: what the agent is doing now ("Thinking" before any output, the call in flight, else
/// "Working for") and
/// the turn's time, which ticks until the turn ends, so the bottom of a running chat always moves.
/// It keeps one id from the Thinking line the prompt opened (LIVE_THINKING), so its row never
/// leaves and comes back.
///
/// Otherwise it is shaped as the turn will fold when it ends: rows before the latest text are
/// its work, so a turn so far only streaming its answer draws no status (it ends without a
/// fold). The line is timed from the prompt and draws its own clock; while text streams, the
/// clock stops at that text's start, where "Worked for" would time the turn if it ended there.
/// The client's empty "typing" placeholder gives way to it.
/// With `sessionStatus` and a todo list, the list sits under the work and the activity line under
/// it takes the status's place (cx-ncc.102, Claude Code desktop's in-session status).
function liveTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  clockOffset: number,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
): AcpmuxRow[] {
  const drawn = turn.filter((row) => row.kind !== "typing");
  // A started chat's card that no row follows yet is not the turn's latest step. The latest step is
  // read before the Codex-style runs fold it: the call it runs is what the live line names.
  let last: AcpmuxRow | undefined;
  for (let index = drawn.length - 1; index >= 0 && !last; index -= 1)
    if (drawn[index]!.kind !== STARTED_SESSIONS) last = drawn[index];
  // The Codex-style live line names the call in flight; a command still running in an earlier run
  // (a parallel `cp` while the agent messages others) leaves its run for the line too.
  const named = lineBelow && liveRuns && last ? lineCall(drawn, last) : undefined;
  const rows = liveRuns ? codexRuns(mergeShortNotes(drawn), named?.tool.id) : drawn;
  // The status ticks on this computer's clock, from the prompt moved onto it.
  const at = user.at + clockOffset;
  if (lineBelow && liveRuns) return codexLiveTurn(user, drawn, rows, last, named, at, clockOffset, sessionStatus);
  if (lineBelow) {
    const shown = withLiveStep(rows, last);
    const plan = sessionStatus
      ? [...shown].reverse().find((row) => row.kind === "plan" && row.plan?.length)
      : undefined;
    // With a todo list the activity line under it is the live line (cx-ncc.102); it is already
    // the turn's last row and ticks from the prompt.
    if (plan && last?.kind !== "assistant") {
      const work = shown.filter((row) => row !== plan);
      return [...work, plan, activityLine(user, work, plan, clockOffset, undefined, true)];
    }
    const status: AcpmuxRow = { id: LIVE_THINKING, version: 2, at, kind: WORKING, below: true };
    const doing = last && inFlightCall(last);
    // A running command's ⌃B hint is the line's, never its row's (WorkingFor.tsx); none while the
    // agent still writes the command (`doingDraft`).
    if (doing?.command) status.doingCommand = true;
    if (doing?.draft) status.doingDraft = true;
    // One running call reads once: not here while its own row names it (`ownRow`).
    if (doing && doing.row !== true) {
      status.doing = doing.title;
      Object.assign(status, sendingTo(doing.tool));
      if (doing.row) Object.assign(status, { doingGroup: doing.row.key, doingGroupOpen: doing.row.open });
    }
    // Before any output it reads "Thinking"; a thought coming in labels itself (ThoughtRow.tsx).
    else if (!last) status.thinkingNow = true;
    // The answer streams under the list, and the line stays under both.
    if (plan) return [...shown.filter((row) => row !== plan && row !== last), plan, last!, status];
    return [...shown, status];
  }
  // A turn with only its started chats' card so far keeps the card under its thinking line.
  if (!last) return [{ id: LIVE_THINKING, version: 1, at: user.at, kind: THINKING }, ...rows];
  const answering = last.kind === "assistant";
  if (answering && rows.length === 1) return rows;
  const status: AcpmuxRow = { id: `${WORKING}-${user.id}`, version: 1, at, kind: WORKING };
  if (answering) Object.assign(status, { version: 2, durationMs: Math.max(0, last.at - user.at) });
  // While a call runs the line names it, as Claude desktop's does (WorkingFor.tsx), unless the
  // call's own row, right under it, already does: one running call reads once. The Codex-style
  // runs draw no call in flight (codexRuns), so there the line always names it.
  else {
    const doing = inFlightCall(last);
    if (doing?.command) status.doingCommand = true;
    if (doing?.draft) status.doingDraft = true;
    if (doing && (liveRuns || doing.row !== true)) {
      status.doing = doing.title;
      Object.assign(status, sendingTo(doing.tool));
      if (doing.row && doing.row !== true && !liveRuns)
        Object.assign(status, { doingGroup: doing.row.key, doingGroupOpen: doing.row.open });
    }
  }
  // The Codex-style runs hold no streaming thought (codexRuns).
  const shown = liveRuns ? rows : withLiveStep(rows, last);
  const plan = sessionStatus ? [...shown].reverse().find((row) => row.kind === "plan" && row.plan?.length) : undefined;
  if (!plan) return [status, ...shown];
  const work = shown.filter((row) => row !== plan);
  // The answer streams under the list; the line has nothing left to say.
  if (answering) return [...work.filter((row) => row !== last), plan, last];
  return [
    ...work,
    plan,
    activityLine(
      user,
      drawn.filter((row) => row !== plan),
      plan,
      clockOffset,
    ),
  ];
}

/// A running turn as the Codex app draws it (Debug toggles `codexToolRuns` and `liveLineBelow`, both
/// on by default): each finished run folded into its summary line between the paragraphs
/// (codexRuns), and at the bottom the turn's one live block, a line that each step replaces in place
/// (Leo 2026-10-20: "Thinking (shimmer) -> Running <short label> -> Thinking"): "Thinking 18s"
/// (the turn's time) while the agent thinks, "Running <what the call does> 13s" while a call runs.
/// Nothing draws over the turn's work (Leo 2026-10-21: a "Working for" there sat far above the
/// line, past his steers). The line keeps the Thinking line's id from send to the turn's end, so it never leaves and
/// comes back. While text streams it waits, quiet (`quietKey`, Thinking.tsx): the words are the
/// motion then. With a todo list (`sessionStatus`) the list sits just over the line.
function codexLiveTurn(
  user: AcpmuxRow,
  drawn: AcpmuxRow[],
  rows: AcpmuxRow[],
  last: AcpmuxRow | undefined,
  named: LineCall | undefined,
  at: number,
  clockOffset: number,
  sessionStatus: boolean,
): AcpmuxRow[] {
  // The one live block sits at the turn's bottom, as the ChatGPT and Codex apps draw it: no
  // "Working for" over the turn (with steers it stood above all of them, far from the line; Leo,
  // 2026-10-21). Between steps it reads "Thinking 18s", timed from the prompt.
  const line: AcpmuxRow = { id: LIVE_THINKING, version: 1, at, kind: THINKING, below: true };
  if (!last) return [...rows, line];
  if (named) {
    const call = named.tool;
    // A command reads its short line; one with no line yet reads its title ("Run make"). While
    // Claude still writes its input (a pending "Bash" with no command, often 20s for a long
    // script) it reads "Writing a command", never "Running" a command that has not started.
    const shell =
      call.kind === "execute" && !call.description && (Boolean(call.command) || isBareShellName(call, call.title));
    line.doing = shell ? (call.command ? shortCommand(call.command) : "") : runningLabel(call, "");
    line.doingShell = shell;
    if (shell && !call.command && call.status === "pending") line.doingDraft = true;
    // A started command shows "⌃B to run in background" on the line, never on a transcript row
    // (Thinking.tsx; Leo, 2026-10-22: "this cmd b to run in background ... it should prob go down").
    if (call.kind === "execute" && !line.doingDraft) line.doingCommand = true;
    Object.assign(line, sendingTo(call));
    line.doingAt = (call.startedAt ?? named.at) + clockOffset;
  } else if (last.kind === "assistant") line.quietKey = `${last.id}:${last.version}`;
  const answering = last.kind === "assistant";
  const plan = sessionStatus ? [...rows].reverse().find((row) => row.kind === "plan" && row.plan?.length) : undefined;
  if (!plan) return [...rows, line];
  const work = rows.filter((row) => row !== plan);
  // The answer streams under the list, the line under both.
  if (answering) return [...work.filter((row) => row !== last), plan, last, line];
  // With a todo list the activity line under it is the live line (cx-ncc.102), as without these
  // toggles; it reads the call in flight from the turn's rows, which the runs no longer hold.
  return [
    ...work,
    plan,
    activityLine(
      user,
      drawn.filter((row) => row !== plan),
      plan,
      clockOffset,
      named?.tool,
      true,
    ),
  ];
}

/// The newest call still running in a live turn's latest row.
function runningCall(
  row: AcpmuxRow,
  matches: (tool: NonNullable<AcpmuxActivity["tool"]>) => boolean = () => true,
): NonNullable<AcpmuxRow["items"]>[number]["tool"] | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (tool && isRunning(tool) && matches(tool)) return tool;
  }
  return undefined;
}

type LineCall = { tool: NonNullable<ReturnType<typeof runningCall>>; at: number };

/// The call the Codex-style live line names: the newest one running in the turn's latest step, else
/// the newest command still running anywhere in the turn, so a command never runs under "Thinking"
/// (Leo, 2026-10-22: "the ran thing basiclly replcaes the thinking usually").
function lineCall(drawn: readonly AcpmuxRow[], last: AcpmuxRow): LineCall | undefined {
  const latest = runningCall(last);
  if (latest) return { tool: latest, at: last.at };
  for (let index = drawn.length - 1; index >= 0; index -= 1) {
    const row = drawn[index]!;
    const tool = runningCall(row, (call) => call.kind === "execute" && !call.background && !isDraftCall(call));
    if (tool) return { tool, at: row.at };
  }
  return undefined;
}

/// The latest step row may still stream its last thought (ThoughtRow.tsx). Its version moves off
/// the stored one, so the row draws again, done, once another row follows it. A started chats'
/// card may follow it (`last` is the latest row that is not one).
function withLiveStep(rows: AcpmuxRow[], last: AcpmuxRow | undefined): AcpmuxRow[] {
  if (last?.kind !== "activity") return rows;
  return rows.map((row) => (row === last ? { ...last, live: true, version: last.version * 2 + 1 } : row));
}

/// The activity line of a running turn: its running tool call as its row names it (a command as
/// itself, an edit by its file name), else the todo in progress. What it names is its text and
/// moves its version, so the memoized row redraws when the call's path arrives; it carries no
/// items, so Find never counts the call's output a second time. Its clock ticks from the prompt.
/// With `named` (the Codex-style runs, `lineCall`) it names that call, the one the runs left out, so
/// a command never leaves its run without the line naming it.
function activityLine(
  user: AcpmuxRow,
  work: AcpmuxRow[],
  plan: AcpmuxRow,
  clockOffset: number,
  named?: NonNullable<AcpmuxActivity["tool"]>,
  below = false,
): AcpmuxRow {
  const running = named
    ? { kind: "tool", text: "", tool: named }
    : work
        .flatMap((row) => (row.kind === "activity" ? (row.items ?? []) : []))
        .reverse()
        .find((item) => item.tool?.status === "pending" || item.tool?.status === "in_progress");
  const label = running?.tool
    ? runningLabel(running.tool, running.text)
    : (plan.plan?.find((entry) => entry.status === "in_progress")?.content ?? "");
  // A started command offers ⌃B here, as on the turn's other live lines (ActivityLine.tsx).
  const command = running?.tool?.kind === "execute" && !isDraftCall(running.tool);
  let version = 1;
  for (let index = 0; index < label.length; index += 1) version = (version * 31 + label.charCodeAt(index)) % 1_000_003;
  const line: AcpmuxRow = {
    id: `${ACTIVITY_LINE}-${user.id}`,
    version: version * 2 + (command ? 1 : 0),
    at: user.at + clockOffset,
    kind: ACTIVITY_LINE,
    text: label,
    // The line below a plan occupies the footer's slot. Keeping the marker on that row lets the
    // estimator and the DOM swap it for `turnSummary` without changing the rows above it.
    ...(below && { below: true }),
  };
  if (command) line.doingCommand = true;
  if (running?.tool) Object.assign(line, sendingTo(running.tool));
  return line;
}

/// The message a call in flight sends, for the live line: "Sending message to tests", never the
/// raw `acpmux send …` line (Leo 2026-10-24: "sending message or sent message to X or Y").
function sendingTo(tool: NonNullable<AcpmuxActivity["tool"]>): Pick<AcpmuxRow, "doingSendTo" | "doingSendSession"> {
  const send = acpmuxSendCall(tool);
  // Only a send still going: one that failed in the background is not "Sending" any more.
  if (send) return send.state === "sending" ? { doingSendTo: send.target } : {};
  if (tool.kind === "execute" && tool.command) return {};
  const call = subsessionCall(tool);
  if (call?.tool !== "send") return {};
  const id = call.sessionId;
  return { doingSendTo: id.length > 12 ? `${id.slice(0, 8)}…` : id, doingSendSession: id };
}

/// A running call in one short line: a command as itself ("Ran …" would say it has finished), a
/// file call by the file's name ("Edit ProductGrid.module.css").
function runningLabel(tool: Parameters<typeof toolLabel>[0], text: string): string {
  const label = toolLabel(tool, text, (command) => command);
  const path = editedPaths(tool)[0];
  if (!path || tool.kind === "execute") return label;
  return `${label.split(/\s+/, 1)[0]} ${path.split("/").pop() || path}`;
}

/// The newest call still running in a live turn's latest row, by its title, and where the
/// transcript draws its own row (`ownRow`).
function inFlightCall(
  row: AcpmuxRow,
):
  | { title: string; command: boolean; draft: boolean; row: OwnRow; tool: NonNullable<AcpmuxActivity["tool"]> }
  | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (!tool || !isRunning(tool)) continue;
    // The row's own label, never the call's raw JSON input; a command reads as itself.
    const title = toolLabel(tool, "", (command) => command).trim();
    const draft = isDraftCall(tool);
    return title
      ? { title, command: tool.kind === "execute", draft, row: ownRow(row, items[index]!), tool }
      : undefined;
  }
  return undefined;
}

/// `true` when the call's own row is always drawn; the disclosure of the group that draws it while
/// open (`open` is its default); nil when no row of its own is drawn.
type OwnRow = true | { key: string; open: boolean } | undefined;

/// Where ToolRows draws a call (TurnRows.tsx groupNode, ToolGroupRow.tsx): a lone call, a message
/// card, a sub-session card and a lone MCP call have their own row; a grouped call shows under its group's line while
/// the group is open, among its latest GROUP_TAIL; a folded run (`foldRun`, codexRuns) shows none
/// until opened. The key is the one groupNode gives the group's disclosure.
function ownRow(row: AcpmuxRow, item: AcpmuxActivity): OwnRow {
  const groups = toolGroups(row.items ?? []);
  const at = groups.findIndex((group) => ("items" in group ? group.items.includes(item) : group.item === item));
  const group = groups[at];
  if (!group || row.foldRun) return undefined;
  if (
    group.type === "item" ||
    group.type === "message" ||
    group.type === "send" ||
    group.type === "subsession" ||
    group.type === "dispatch" ||
    (group.type === "mcp" && group.items.length === 1)
  )
    return true;
  const kind = group.type === "mcp" ? "mcp" : group.kind;
  const tail = kind === "mcp" || kind === "edits" || group.items.indexOf(item) >= tailStart(group.items);
  if (!tail) return undefined;
  const key = `group:${kind}:${group.items[0]!.tool!.id || `${row.id}:${at}`}`;
  return { key, open: kind !== "mcp" && kind !== "edits" };
}

/// The drawn states of one Codex-style run, each its own version offset so a memoized row redraws
/// on every change between them (App.tsx compares versions): 1 the live latest run, 2 an earlier
/// run, 3 an ended turn's open fold, 4 an earlier run whose running command the live line holds.
const RUN_STATES = 5;

/// A running turn's runs as the Codex desktop app draws them (cx-ncc.108): each run folds into its
/// summary line between the paragraphs ("Read 6 files, ran 4 commands", or one group's "Ran 3
/// commands"), the latest one too as its calls finish, and opens on a click. The call in flight and
/// a thought still coming are not in the run: the turn's live line names them (WorkingFor.tsx
/// `doing`, "Thinking") and each step replaces it in place. A call still running in an earlier run
/// (a background shell) stays in its run, except the command the live line names (`named`,
/// `lineCall`), which reads once, on the line. Each derived row's version moves with its drawn state.
function codexRuns(rows: AcpmuxRow[], named?: string): AcpmuxRow[] {
  // A started chats' card after the run is not a step: the run before it is still in flight.
  let latest = rows.length - 1;
  while (latest > 0 && rows[latest]!.kind === STARTED_SESSIONS) latest -= 1;
  return rows.flatMap((row, index) => {
    if (row.kind !== "activity") return [row];
    // A run that edited folds too, its edits named on the line ("Edited 2 files, read 3 files, ran a
    // command"), as the Codex app collapses a run (Leo 2026-10-22: "this is pretty good ui: … the
    // collapsing i mean"); the turn's edited-files card lists them when it ends. One with a file
    // change still waiting for its permission stays as it is, so the change it asks about stays in
    // sight (an ended turn's folded run keeps it in sight too: TurnRows.tsx `staysInSight`).
    if ((row.items ?? []).some((item) => awaitsPermission(item.tool)))
      return [{ ...row, foldRun: false, version: row.version * RUN_STATES }];
    // An earlier run draws no call that has nothing to show yet; its row comes with its input.
    if (index !== latest)
      return withoutDrafts(row).flatMap((kept) => {
        const items = kept.items ?? [];
        const shown = named === undefined ? items : items.filter((item) => item.tool?.id !== named);
        if (!shown.length) return [];
        // Its version says whether the line holds its command, which moves without the row's, and
        // differs from every other state of the run (`RUN_STATES`).
        const lined = shown.length !== items.length;
        return [
          { ...kept, items: shown, settled: true, foldRun: true, version: row.version * RUN_STATES + (lined ? 4 : 2) },
        ];
      });
    // The latest run: what is happening now leaves it for the live line, so the run holds only
    // finished steps and never grows a stack of live rows (Leo 2026-10-20: "rows pile up instead
    // of replacing each other").
    const all = row.items ?? [];
    const items = all.filter(
      (item, at) => !(item.tool ? isRunning(item.tool) : at === all.length - 1 && item.kind !== "tool"),
    );
    if (!items.length) return [];
    return [{ ...row, items, settled: true, foldRun: true, version: row.version * RUN_STATES + 1 }];
  });
}

/// Narration short enough to fold into the work around it: a short paragraph, under about three
/// lines at the pane's width.
export const SHORT_NOTE_CHARS = 160;
const TAKEAWAY_LINES = 3;
/// A reply that reads as a takeaway, not narration of the work: over about three lines, or with a
/// question, a list, a link, a code block or a second paragraph (Leo, 2026-10-21). Inline code alone
/// does not make one: narration names files and calls ("Reading `client.ts` next."), and that is
/// the work Lawrence asked to collapse; a short note keeps the fold it had before. Another agent's words
/// always are. Shared by the finished turn's folds (``takeawaysIn``) and the running turn's runs
/// (``mergeShortNotes``).
export function isTakeaway(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant") return false;
  const text = (row.text ?? "").trim();
  if (!text) return false;
  return (
    Boolean(row.incoming) ||
    text.length > SHORT_NOTE_CHARS ||
    text.split("\n").length > TAKEAWAY_LINES ||
    /\?|```|~~~|\n\s*\n|^\s*(?:[-*+]|\d+[.)])\s|\]\(|https?:\/\//m.test(text)
  );
}
const isShortNote = (row: AcpmuxRow | undefined) => row !== undefined && isReply(row) && !isTakeaway(row);
const isRun = (row: AcpmuxRow | undefined) => row?.kind === "activity" && !isEdit(row);

/// Two runs with only a short interim note between them ("Relay the decisions, then answer.") are
/// one stretch of work (Leo 2026-10-20: "it can consolidate a ton of these tool calls"): they draw
/// as one run, the note folded in among its calls as a quiet line (`note` item, TurnRows.tsx). The
/// merged row keeps the first run's id; its version moves with each part's.
export function mergeShortNotes(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    const previous = out.at(-1);
    if (isRun(previous) && isShortNote(row) && isRun(rows[index + 1])) {
      const next = rows[index + 1]!;
      out[out.length - 1] = {
        ...previous!,
        items: [...(previous!.items ?? []), { kind: "note", text: row.text!.trim() }, ...(next.items ?? [])],
        toolCount: (previous!.toolCount ?? 0) + (next.toolCount ?? 0),
        joined: [...(previous!.joined ?? [previous!.id]), row.id, next.id],
        version: mixVersion(mixVersion(previous!.version, row.version), next.version),
      };
      index += 1;
    } else out.push(row);
  }
  return out.length === rows.length ? (rows as AcpmuxRow[]) : out;
}

const mixVersion = (a: number, b: number) => (a * 1_009 + b * 7 + 1) % 2_147_483_647;

/// The "Worked for" fold that holds `rows[index]`: the one of the part of its turn it ran in, the
/// nearest prompt's or drawn steer's before it (shapeTurn `turnParts`), past a prompt not yet sent
/// or refused, which draws among the turn's rows and opens nothing, unless it is the chat's first
/// prompt: turnView opens the first turn with it. Find and a shell's row open it to reveal a row the
/// fold hides.
export function turnFoldFor(rows: readonly AcpmuxRow[], index: number): string | undefined {
  let unsent: AcpmuxRow | undefined;
  for (let at = Math.min(index, rows.length - 1); at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "user" && isUnsent(row)) {
      unsent = row;
      continue;
    }
    if (opensTurn(row) || (continuesTurn(row) && row.incoming?.kind !== "hidden")) return partFoldFor(rows, at, index);
  }
  return unsent && `${WORKED}-${unsent.id}`;
}

/// The fold that holds `rows[index]` in the part `rows[opener]` opens: the stretch of work it is
/// in (foldSegments), or the part's first fold.
function partFoldFor(rows: readonly AcpmuxRow[], opener: number, index: number): string {
  let end = opener + 1;
  // The part ends where shapeTurn's does (turnParts): at the next accepted prompt, a drawn steer or
  // the turn's summary. A prompt not yet sent or refused, and a steer that draws nothing, sit in it.
  // A summary a steer continued (shapedTurn drops it from the turn) does not end the part either.
  const endsPart = (at: number) => {
    const row = rows[at]!;
    if (row.kind === "turnSummary") return !(row.continued && steerFollows(rows, at));
    return (opensTurn(row) && !isUnsent(row)) || (continuesTurn(row) && row.incoming?.kind !== "hidden");
  };
  while (end < rows.length && !endsPart(end)) end += 1;
  const target = rows[index];
  const part = rows.slice(opener + 1, end).filter((row) => row.kind !== "user");
  const segment = foldSegments(rows[opener]!, part).find(
    (stretch) => stretch.rows.includes(target!) || stretch.after?.includes(target!),
  );
  return `${WORKED}-${(segment?.anchor ?? rows[opener]!).id}`;
}

/// A steer comes after `rows[at]` in its turn, before the next accepted prompt (shapedTurn drops a
/// continued summary that one follows).
function steerFollows(rows: readonly AcpmuxRow[], at: number): boolean {
  for (let next = at + 1; next < rows.length; next += 1) {
    const row = rows[next]!;
    if (continuesTurn(row)) return true;
    if (opensTurn(row) && !isUnsent(row)) return false;
  }
  return false;
}

/// Where to bring one message of the chat into view (a link's `message=<id>`, links.ts): the first
/// of the message's rows the transcript already draws, else its first row and the "Worked for" fold
/// that hides it. A tool call ends the reply it interrupts, so one message is several rows and only
/// a turn's last one stays outside the fold: a link to a message that worked lands on a folded row,
/// and the fold has to open before the transcript can scroll to it. Undefined when the chat's rows
/// hold none of `messageRows` (another machine's transcript, or history not loaded yet).
export function messageRevealTarget(
  rows: readonly AcpmuxRow[],
  drawn: readonly AcpmuxRow[],
  messageRows: readonly string[],
): { rowId: string; fold?: string } | undefined {
  const places = messageRows.map((id) => rows.findIndex((row) => row.id === id)).filter((at) => at >= 0);
  if (places.length === 0) return undefined;
  const shown = places.find((at) => findRowIndex(drawn, rows[at]!.id) >= 0);
  if (shown !== undefined) return { rowId: rows[shown]!.id };
  const at = places[0]!;
  return { rowId: rows[at]!.id, fold: turnFoldFor(rows, at) };
}

/// The footer of the drawn turn that `rows[from]` is in (the turn's summary row), looking forward
/// from it to the next turn's prompt; a steer drawn inside the turn does not end it.
export function turnFooterFrom(rows: readonly AcpmuxRow[], from: number): string | undefined {
  for (let index = from; index >= 0 && index < rows.length; index += 1) {
    if (index > from && opensTurn(rows[index]!)) return undefined;
    if (rows[index]!.kind === "turnSummary") return rows[index]!.id;
  }
  return undefined;
}

/// A folded copy of an activity row is drawn as tool rows, never as the edited-files card.
export const isFoldedCopy = (row: AcpmuxRow) => row.id.endsWith(FOLDED);
