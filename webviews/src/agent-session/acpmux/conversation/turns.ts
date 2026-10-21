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
import { isSubagentGroup, SUBAGENT_DONE } from "../subagents/subagentRows";
import { STARTED_SESSIONS } from "../started/startedSessions";
import { QUESTION_RECORD } from "../question/record";
import type { Translate } from "../i18n";
import { editedPaths, isBareShellName, toolLabel } from "../toolPaths";
import { shortCommand } from "./shortCommand";
import { GROUP_TAIL } from "./ToolGroupRow";
import { isRunning, toolGroups } from "./toolGroups";

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
    let from = 0;
    while (from < rows.length && from < shared.length && rows[from] === shared[from]) from += 1;
    while (reuse < previous.starts.length && previous.starts[reuse]! < from) reuse += 1;
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
  return { source: rows, expanded, clockOffset, liveRuns, lineBelow, lead, starts, times, dated, ends, rows: out };
}

/// A turn as drawn, kept while its rows (by identity) and what shapes them stay the same: a long
/// chat's snapshot rebuilds only the turns that changed, and an unchanged turn's derived rows stay
/// the same objects, so the row memos and the height cache keep them.
type ShapedTurn = {
  /// The turn's rows after its prompt, held prompts included, as last shaped.
  source: readonly AcpmuxRow[];
  open: boolean;
  last: boolean;
  clockOffset: number;
  dated: boolean;
  liveRuns: boolean;
  rows: AcpmuxRow[];
};
const shapedTurns = new WeakMap<AcpmuxRow, ShapedTurn>();

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
  const open = expanded.size > 0 && expanded.has(`${WORKED}-${user.id}`);
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
  }
  if (!live) shapedTurns.set(user, { source, open, last, clockOffset, dated, liveRuns, rows: shaped });
  return shaped;
}

const isAnswer = (row: AcpmuxRow) => row.kind === "assistant";

/// A tool call after a turn's last text: the turn ended on work, so that text was interim.
/// Edits join the turn's card and render calls draw as their own cards, so neither counts; a
/// step that edited and then ran something does.
const isWork = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool && !isEditTool(item.tool) && !renderCall(item.tool));

/// Where a finished turn's answer is in `rows`: the last text, unless the turn went on to work
/// after it (-1: no answer, so all of it folds, as the Codex and Claude desktop apps fold it).
function answerAt(rows: readonly AcpmuxRow[]): number {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (isAnswer(row)) return at;
    if (isWork(row)) return -1;
  }
  return -1;
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
        ? turn.map(endedPlan)
        : settledWithoutSummary(turn);
  const summary = turn[end]!;
  const body = turn.slice(0, end);
  const final = answerAt(body);
  const answer = final >= 0 ? body[final] : undefined;
  // Work before the answer folds away (all of it, when the turn ended without one); edits
  // also close the turn as their card. Subagent groups and the todo list stay out, under the
  // fold's line.
  const before = (final >= 0 ? body.slice(0, final) : body).filter((row) => row.kind !== "typing");
  const answered = steeredAnswers(before);
  const work = before.filter((row) => !staysOut(row) && !answered.has(row));
  const groups = before.filter((row) => staysOut(row) || answered.has(row));
  const after = final >= 0 ? body.slice(final + 1) : [];
  // Edits after the answer join the card too, so its Undo covers the whole turn.
  const edits = [...work.filter(isEdit), ...after.filter(isEdit)];
  const rest = after.filter((row) => !isEdit(row));
  const shaped: AcpmuxRow[] = [];
  // A derived row's version must change whenever what it draws does: the memoized rows and the
  // height cache compare versions only. Answer versions stay far below VERSION_SPAN.
  const version = summary.version * VERSION_SPAN + (answer?.version ?? 0);
  if (work.length) {
    const id = `${WORKED}-${user.id}`;
    const open = expanded.has(id);
    shaped.push({
      id,
      version: version * 2 + (open ? 1 : 0),
      at: user.at,
      kind: WORKED,
      status: summary.status,
      toolCount: summary.toolCount,
      durationMs: answer ? Math.max(0, answer.at - user.at) : (summary.durationMs ?? Math.max(0, summary.at - user.at)),
    });
    // Open, each run of its work folds into its summary line between the commentary, as in a
    // running turn (codexRuns).
    if (open)
      shaped.push(
        ...(liveRuns ? mergeShortNotes(work) : work).map((row) => ({
          ...row,
          id: isEdit(row) ? `${row.id}${FOLDED}` : row.id,
          settled: true,
          // A folded run draws otherwise, so its version moves (memos compare versions).
          ...(liveRuns && row.kind === "activity" && !isEdit(row) && { foldRun: true, version: row.version * 4 + 3 }),
        })),
      );
  }
  shaped.push(...groups.map(endedPlan), ...renderRows(body, version));
  if (answer) shaped.push(answer);
  shaped.push(...rest.map(endedPlan), ...editsCard(edits));
  const preview = turnPreviewCardsOn() ? turnPreviewUrl(user, turn) : undefined;
  if (preview) shaped.push({ id: `${PREVIEW}-${user.id}`, version, at: summary.at, kind: PREVIEW, text: preview });
  // The footer copies the answer, so it carries the answer's text; the last turn's also retries
  // its prompt, and stops offering to once a later prompt goes (or waits to).
  shaped.push({
    ...summary,
    folded: work.length > 0,
    text: answer?.text ?? summary.text,
    // Retry sends the prompt as the agent got it: an incoming message with its sender. A
    // notification is the harness's, not a prompt to send again (incomingMessage.ts).
    ...(retryable &&
      user.incoming?.kind !== "notice" &&
      (user.resend ?? user.text) && {
        prompt: user.resend ?? user.text,
        retryRowId: user.id,
        retryAttachments: user.retryAttachments,
      }),
    version: version * 2 + (retryable ? 1 : 0),
  });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  // A turn the agent started on its own while still working keeps its plan live.
  shaped.push(...turn.slice(end + 1).map(live ? (row) => row : endedPlan));
  return shaped;
}

const VERSION_SPAN = 1_000_000;

/// In a turn that took steers, the reply each steer followed: the text that ended the part of the
/// turn before it, when no work came after that text. It answered what was asked then, so it draws
/// beside the steer rather than folding into the turn's work.
function steeredAnswers(rows: readonly AcpmuxRow[]): Set<AcpmuxRow> {
  const answers = new Set<AcpmuxRow>();
  let from = 0;
  rows.forEach((row, at) => {
    if (!continuesTurn(row)) return;
    const reply = answerAt(rows.slice(from, at));
    if (reply >= 0) answers.add(rows[from + reply]!);
    from = at + 1;
  });
  return answers;
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
/// below.
const staysOut = (row: AcpmuxRow) =>
  // A steer: the person's own words are never folded away.
  continuesTurn(row) ||
  isSubagentGroup(row) ||
  (row.kind === "plan" && row.plan !== undefined) ||
  row.kind === "backgroundTask" ||
  // Where a subagent ended (the tray showed it while it ran, subagents/runningTray.ts).
  row.kind === SUBAGENT_DONE ||
  // A compaction or a move to the fallback harness changes what the rest of the turn knows or
  // who answers it; folded, nobody would see it happened.
  row.kind === "compaction" ||
  row.kind === "failover" ||
  // A paused agent pair waits for the person's Resume.
  row.kind === "agentPair" ||
  // Where the session started: what it runs on and how it compacts.
  row.kind === "sessionStart" ||
  // A session offer waits for the person's Start or Dismiss.
  row.kind === "sessionOffer" ||
  // A chat the turn started keeps its card in sight (started/startedSessions.ts).
  row.kind === STARTED_SESSIONS ||
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
  return [...rows.filter((row) => !isEdit(row)).map(endedPlan), ...editsCard(rows.filter(isEdit))];
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
  const rows = liveRuns ? codexRuns(mergeShortNotes(drawn)) : drawn;
  // The status ticks on this computer's clock, from the prompt moved onto it.
  const at = user.at + clockOffset;
  if (lineBelow && liveRuns) return codexLiveTurn(user, drawn, rows, last, at, clockOffset, sessionStatus);
  if (lineBelow) {
    const shown = withLiveStep(rows, last);
    const plan = sessionStatus
      ? [...shown].reverse().find((row) => row.kind === "plan" && row.plan?.length)
      : undefined;
    // With a todo list the activity line under it is the live line (cx-ncc.102); it is already
    // the turn's last row and ticks from the prompt.
    if (plan && last?.kind !== "assistant") {
      const work = shown.filter((row) => row !== plan);
      return [...work, plan, activityLine(user, work, plan, clockOffset)];
    }
    const status: AcpmuxRow = { id: LIVE_THINKING, version: 2, at, kind: WORKING, below: true };
    const doing = last && inFlightCall(last);
    // One running call reads once: not here while its own row names it (`ownRow`).
    if (doing && doing.row !== true) {
      status.doing = doing.title;
      if (doing.command) status.doingCommand = true;
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
    if (doing && (liveRuns || doing.row !== true)) {
      status.doing = doing.title;
      if (doing.command) status.doingCommand = true;
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
/// on by default): "Working for 42s" over the turn's work, as before; each finished run folded into
/// its summary line between the paragraphs (codexRuns); and at the bottom one live line that each
/// step replaces in place (Leo 2026-10-20: "Thinking (shimmer) -> Running <short label> ->
/// Thinking"): "Thinking" while the agent thinks, "Running <what the call does> 13s" while a call
/// runs. The line keeps the Thinking line's id from send to the turn's end, so it never leaves and
/// comes back. While text streams it waits, quiet (`quietKey`, Thinking.tsx): the words are the
/// motion then. With a todo list (`sessionStatus`) the list sits just over the line.
function codexLiveTurn(
  user: AcpmuxRow,
  drawn: AcpmuxRow[],
  rows: AcpmuxRow[],
  last: AcpmuxRow | undefined,
  at: number,
  clockOffset: number,
  sessionStatus: boolean,
): AcpmuxRow[] {
  const line: AcpmuxRow = { id: LIVE_THINKING, version: 1, at, kind: THINKING, below: true };
  // Before any output, "Thinking 4s" times the turn from the prompt.
  if (!last) return [...rows, line];
  line.untimed = true;
  const call = runningCall(last);
  if (call) {
    // A command reads its short line; one with no line yet reads its title ("Run make"), or
    // "Running a command" when that is only the shell tool's name ("Bash").
    const shell =
      call.kind === "execute" && !call.description && (Boolean(call.command) || isBareShellName(call, call.title));
    line.doing = shell ? (call.command ? shortCommand(call.command) : "") : runningLabel(call, "");
    line.doingShell = shell;
    // A command shows "⌃B to run in background" on the line, where its own row would (Thinking.tsx).
    if (call.kind === "execute") line.doingCommand = true;
    line.doingAt = (call.startedAt ?? last.at) + clockOffset;
    line.untimed = false;
  } else if (last.kind === "assistant") line.quietKey = `${last.id}:${last.version}`;
  const answering = last.kind === "assistant";
  const header: AcpmuxRow[] =
    answering && drawn.length === 1
      ? []
      : [
          {
            id: `${WORKING}-${user.id}`,
            version: answering ? 2 : 1,
            at,
            kind: WORKING,
            ...(answering && { durationMs: Math.max(0, last.at - user.at) }),
          },
        ];
  const plan = sessionStatus ? [...rows].reverse().find((row) => row.kind === "plan" && row.plan?.length) : undefined;
  if (!plan) return [...header, ...rows, line];
  const work = rows.filter((row) => row !== plan);
  // The answer streams under the list, the line under both.
  if (answering) return [...header, ...work.filter((row) => row !== last), plan, last, line];
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
    ),
  ];
}

/// The newest call still running in a live turn's latest row.
function runningCall(row: AcpmuxRow): NonNullable<AcpmuxRow["items"]>[number]["tool"] | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (tool && isRunning(tool)) return tool;
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
function activityLine(user: AcpmuxRow, work: AcpmuxRow[], plan: AcpmuxRow, clockOffset: number): AcpmuxRow {
  const running = work
    .flatMap((row) => (row.kind === "activity" ? (row.items ?? []) : []))
    .reverse()
    .find((item) => item.tool?.status === "pending" || item.tool?.status === "in_progress");
  const label = running?.tool
    ? runningLabel(running.tool, running.text)
    : (plan.plan?.find((entry) => entry.status === "in_progress")?.content ?? "");
  let version = 1;
  for (let index = 0; index < label.length; index += 1) version = (version * 31 + label.charCodeAt(index)) % 1_000_003;
  return { id: `${ACTIVITY_LINE}-${user.id}`, version, at: user.at + clockOffset, kind: ACTIVITY_LINE, text: label };
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
function inFlightCall(row: AcpmuxRow): { title: string; command: boolean; row: OwnRow } | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (!tool || !isRunning(tool)) continue;
    // The row's own label, never the call's raw JSON input; a command reads as itself.
    const title = toolLabel(tool, "", (command) => command).trim();
    return title ? { title, command: tool.kind === "execute", row: ownRow(row, items[index]!) } : undefined;
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
    group.type === "subsession" ||
    (group.type === "mcp" && group.items.length === 1)
  )
    return true;
  const kind = group.type === "mcp" ? "mcp" : group.kind;
  const tail = kind === "mcp" || kind === "edits" || group.items.indexOf(item) >= group.items.length - GROUP_TAIL;
  if (!tail) return undefined;
  const key = `group:${kind}:${group.items[0]!.tool!.id || `${row.id}:${at}`}`;
  return { key, open: kind !== "mcp" && kind !== "edits" };
}

/// A running turn's runs as the Codex desktop app draws them (cx-ncc.108): each run folds into its
/// summary line between the paragraphs ("Read files, ran commands", or one group's "Ran 3
/// commands"), the latest one too as its calls finish, and opens on a click. The call in flight and
/// a thought still coming are not in the run: the turn's live line names them (WorkingFor.tsx
/// `doing`, "Thinking") and each step replaces it in place. A call still running in an earlier run
/// (a background shell) stays in its run. Each derived row's version moves with its drawn state.
function codexRuns(rows: AcpmuxRow[]): AcpmuxRow[] {
  // A started chats' card after the run is not a step: the run before it is still in flight.
  let latest = rows.length - 1;
  while (latest > 0 && rows[latest]!.kind === STARTED_SESSIONS) latest -= 1;
  return rows.flatMap((row, index) => {
    if (row.kind !== "activity" || isEdit(row)) return [row];
    if (index !== latest) return [{ ...row, settled: true, foldRun: true, version: row.version * 4 + 2 }];
    // The latest run: what is happening now leaves it for the live line, so the run holds only
    // finished steps and never grows a stack of live rows (Leo 2026-10-20: "rows pile up instead
    // of replacing each other").
    const all = row.items ?? [];
    const items = all.filter(
      (item, at) => !(item.tool ? isRunning(item.tool) : at === all.length - 1 && item.kind !== "tool"),
    );
    if (!items.length) return [];
    return [{ ...row, items, settled: true, foldRun: true, version: row.version * 4 + 1 }];
  });
}

/// An interim note short enough to fold into the work around it: one short paragraph, no code.
export const SHORT_NOTE_CHARS = 160;
const isShortNote = (row: AcpmuxRow | undefined) =>
  row?.kind === "assistant" &&
  !row.incoming &&
  (row.text ?? "").trim().length > 0 &&
  (row.text ?? "").trim().length <= SHORT_NOTE_CHARS &&
  !/\n\s*\n|```/.test(row.text ?? "");
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

/// The "Worked for" fold that holds `rows[index]`: the one of the turn its prompt opened, past
/// steers (turnStart.ts). Find and a shell's row open it to reveal a row the fold hides.
export function turnFoldFor(rows: readonly AcpmuxRow[], index: number): string | undefined {
  for (let at = Math.min(index, rows.length - 1); at >= 0; at -= 1)
    if (opensTurn(rows[at]!)) return `${WORKED}-${rows[at]!.id}`;
  return undefined;
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
