// A turn in the transcript: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After the reference prototype's
// derive.ts (`deriveTurn`, `formatDuration`).
//
// Stop-gap seam: acpmux owns the turn structure (spec acp-ui.md, OWNERSHIP-PRINCIPLES.md). When
// acpmux serves turn-structured rows (`acp.view.subscribe`, `_acpmux/view`), `turnView` becomes
// a field-for-field mapping of them and nothing else in the pane changes.
import type { AcpmuxRow } from "../model";
import { turnPreviewUrl } from "./previewUrl";
import { renderCall } from "./renderCall";
import { showsTimestamp, type TurnTimes } from "./timestamps";
import { isSubagentGroup } from "../subagents/subagentRows";
import type { Translate } from "../i18n";

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
/// A row added for an ended turn that started or mentioned a local web page (previewUrl.ts): its
/// preview card, with the page's address as its text.
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
/// or "34 previous messages" for a turn whose timing is unknown (a reloaded turn without a
/// summary). It shows no tool-call count.
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
/// computer's clock, so its "Working for" counts from the prompt.
export function turnView(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  options: { now?: number; working?: boolean; clockOffset?: number; liveRuns?: boolean } = {},
): AcpmuxRow[] {
  return turnViewFrom(rows, expanded, options).rows;
}

/// A turn view (``turnViewFrom``) with what it was drawn from, for the next snapshot to build on.
export type TurnView = {
  source: readonly AcpmuxRow[];
  expanded: ReadonlySet<string>;
  clockOffset: number;
  liveRuns: boolean;
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
  }: { now?: number; working?: boolean; clockOffset?: number; liveRuns?: boolean } = {},
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
  // and neither ends the turn nor folds into it. Indexes, not arrays: a long chat's snapshot only
  // copies the rows of a turn that changed (shapedTurn).
  while (index < rows.length) {
    const start = index++;
    let answerAt: number | undefined;
    while (index < rows.length && (rows[index]!.kind !== "user" || isUnsent(rows[index]!))) {
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
    for (const row of shapedTurn(rows, start, end, expanded, working && last, last, clockOffset, dated[at]!, liveRuns))
      out.push(row);
    ends.push(out.length);
  }
  return { source: rows, expanded, clockOffset, liveRuns, lead, starts, times, dated, ends, rows: out };
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
    cached.source.length === end - start - 1
  ) {
    let same = true;
    for (let index = start + 1; same && index < end; index += 1)
      same = cached.source[index - start - 1] === rows[index];
    if (same) return cached.rows;
  }
  const source = rows.slice(start + 1, end);
  const turn = source.filter((row) => row.kind !== "user");
  const held = turn.length === source.length ? [] : source.filter((row) => row.kind === "user");
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
  } else
    shaped = [
      ...date,
      user,
      ...shapeTurn(user, turn, expanded, live, last, last && held.length === 0, clockOffset, liveRuns),
      ...held,
    ];
  if (!live) shapedTurns.set(user, { source, open, last, clockOffset, dated, rows: shaped });
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
): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens, under its live status.
  // An earlier turn without a summary ended long ago (a later prompt follows it): it folds as
  // a reloaded turn without timing. The last one may only be waiting for its
  // summary, so it draws as it came.
  if (end < 0)
    return live
      ? liveTurn(user, turn, clockOffset, liveRuns)
      : last
        ? turn
        : settledWithoutSummary(user, turn, expanded);
  const summary = turn[end]!;
  const body = turn.slice(0, end);
  const final = answerAt(body);
  const answer = final >= 0 ? body[final] : undefined;
  // Work before the answer folds away (all of it, when the turn ended without one); edits
  // also close the turn as their card. Subagent groups and the todo list stay out, under the
  // fold's line.
  const before = (final >= 0 ? body.slice(0, final) : body).filter((row) => row.kind !== "typing");
  const work = before.filter((row) => !staysOut(row));
  const groups = before.filter(staysOut);
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
    if (open)
      shaped.push(...work.map((row) => ({ ...row, id: isEdit(row) ? `${row.id}${FOLDED}` : row.id, settled: true })));
  }
  shaped.push(...groups, ...renderRows(body, version));
  if (answer) shaped.push(answer);
  shaped.push(...rest, ...editsCard(edits));
  const preview = turnPreviewUrl(user, turn);
  if (preview) shaped.push({ id: `${PREVIEW}-${user.id}`, version, at: summary.at, kind: PREVIEW, text: preview });
  // The footer copies the answer, so it carries the answer's text; the last turn's also retries
  // its prompt, and stops offering to once a later prompt goes (or waits to).
  shaped.push({
    ...summary,
    folded: work.length > 0,
    text: answer?.text ?? summary.text,
    ...(retryable && user.text && { prompt: user.text, retryRowId: user.id, retryAttachments: user.retryAttachments }),
    version: version * 2 + (retryable ? 1 : 0),
  });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  shaped.push(...turn.slice(end + 1));
  return shaped;
}

const VERSION_SPAN = 1_000_000;

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
  isSubagentGroup(row) ||
  (row.kind === "plan" && row.plan !== undefined) ||
  row.kind === "backgroundTask" ||
  // A compaction or a move to the fallback harness changes what the rest of the turn knows or
  // who answers it; folded, nobody would see it happened.
  row.kind === "compaction" ||
  row.kind === "failover" ||
  // Where the session started: what it runs on and how it compacts.
  row.kind === "sessionStart" ||
  // A session offer waits for the person's Start or Dismiss.
  row.kind === "sessionOffer";

/// A turn that ended without a summary (history paged in from before acpmux kept one, or a
/// turn a restart cut off): its work folds under "N previous messages", like any
/// reloaded turn without timing, and its answer and edits draw after it.
function settledWithoutSummary(user: AcpmuxRow, turn: AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  const final = answerAt(rows);
  const before = final >= 0 ? rows.slice(0, final) : rows;
  const work = before.filter((row) => !staysOut(row));
  if (work.length === 0) return rows;
  const id = `${WORKED}-${user.id}`;
  const open = expanded.has(id);
  const edits = work.filter(isEdit);
  const previous = work.reduce((count, row) => count + (row.kind === "activity" ? (row.items?.length ?? 1) : 1), 0);
  const version = work.reduce((sum, row) => sum + row.version, 0);
  return [
    { id, version: version * 2 + (open ? 1 : 0), at: user.at, kind: WORKED, previous },
    ...(open ? work.map((row) => ({ ...row, id: isEdit(row) ? `${row.id}${FOLDED}` : row.id, settled: true })) : []),
    ...before.filter(staysOut),
    ...(final >= 0 ? rows.slice(final) : []),
    ...editsCard(edits),
  ];
}

/// The live status, shaped as the turn will fold when it ends: rows before the latest text are
/// its work, so a turn so far only streaming its answer draws no status (it ends without a
/// fold). The line is timed from the prompt and draws its own clock; while text streams, the
/// clock stops at that text's start, where "Worked for" would time the turn if it ended there.
/// The client's empty "typing" placeholder gives way to it.
function liveTurn(user: AcpmuxRow, turn: AcpmuxRow[], clockOffset: number, liveRuns = false): AcpmuxRow[] {
  const drawn = turn.filter((row) => row.kind !== "typing");
  const rows = liveRuns ? codexRuns(drawn) : drawn;
  const last = rows.at(-1);
  if (!last) return [{ id: LIVE_THINKING, version: 1, at: user.at, kind: THINKING }];
  const answering = last.kind === "assistant";
  if (answering && rows.length === 1) return rows;
  // The status ticks on this computer's clock, from the prompt moved onto it.
  const status: AcpmuxRow = { id: `${WORKING}-${user.id}`, version: 1, at: user.at + clockOffset, kind: WORKING };
  if (answering) Object.assign(status, { version: 2, durationMs: Math.max(0, last.at - user.at) });
  // The latest step row may still stream its last thought (ThoughtRow.tsx). Its version moves off
  // the stored one, so the row draws again, done, once another row follows it.
  if (last.kind === "activity")
    return [status, ...rows.slice(0, -1), { ...last, live: true, version: last.version * 2 + 1 }];
  return [status, ...rows];
}

/// A running turn's runs as the Codex desktop app draws them (cx-ncc.108): a run that text
/// followed settles into its summary line, as in an open "Worked for"; the run in flight
/// (`inFlight`) shows only its newest call, so its line replaces itself instead of growing into a
/// list. Each derived row's version moves with its drawn state.
function codexRuns(rows: AcpmuxRow[]): AcpmuxRow[] {
  return rows.map((row, index) => {
    if (row.kind !== "activity" || isEdit(row)) return row;
    return index === rows.length - 1
      ? { ...row, inFlight: true, version: row.version * 4 + 1 }
      : { ...row, settled: true, version: row.version * 4 + 2 };
  });
}

/// A folded copy of an activity row is drawn as tool rows, never as the edited-files card.
export const isFoldedCopy = (row: AcpmuxRow) => row.id.endsWith(FOLDED);
