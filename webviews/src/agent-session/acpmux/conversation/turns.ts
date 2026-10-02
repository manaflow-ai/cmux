// The transcript as Codex draws a turn: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After codex-atlas-clone's
// derive.ts (`deriveTurn`, `formatDuration`).
//
// Stop-gap seam: acpmux owns the turn structure (spec acp-ui.md, OWNERSHIP-PRINCIPLES.md). When
// acpmux serves turn-structured rows (`acp.view.subscribe`, `_acpmux/view`), `turnView` becomes
// a field-for-field mapping of them and nothing else in the pane changes.
import type { AcpmuxRow } from "../model";
import { timestampTurns } from "./timestamps";
import { t } from "../i18n";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
/// A row added by this pass: the timestamp line over a turn (timestamps.ts).
export const DATE = "date";
/// Rows added for the turn still running: "Thinking" until it has output, then a ticking
/// "Working for 42s" line over its work, where "Worked for" lands when the turn ends.
export const THINKING = "thinking";
export const WORKING = "working";
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

export const toolCalls = (count = 0) => (count === 1 ? "1 tool call" : `${count} tool calls`);

/// The disclosure's label, as Codex words it: "Worked for 1m 16s", "You stopped after 40s",
/// or "34 previous messages" for a turn whose timing is unknown (a reloaded turn without a
/// summary). Codex shows no tool-call count here.
export function workedLabel(row: AcpmuxRow): string {
  if (row.previous !== undefined)
    return row.previous === 1 ? t("turn.previous.one") : t("turn.previous.other", { n: row.previous });
  if (row.durationMs === undefined) return toolCalls(row.toolCount);
  const time = formatDuration(row.durationMs);
  return row.status === "cancelled" ? t("turn.stopped", { time }) : t("turn.worked", { time });
}

const isEdit = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");

/// The rows to draw. `expanded` holds the ids of open disclosures; `working` says the last
/// turn is still running (the snapshot's `isWorking`); `now` dates the turns (timestamps.ts).
export function turnView(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  { now = Date.now(), working = false }: { now?: number; working?: boolean } = {},
): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  let index = 0;
  // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are.
  while (index < rows.length && rows[index]!.kind !== "user") out.push(rows[index++]!);
  const loadedFromStart = index === 0;
  const turns: { user: AcpmuxRow; turn: AcpmuxRow[]; held: AcpmuxRow[] }[] = [];
  while (index < rows.length) {
    const user = rows[index++]!;
    const turn: AcpmuxRow[] = [];
    // A prompt not yet accepted (sent while this turn runs, or refused) sorts among this turn's
    // rows by its send time; it neither ends the turn nor folds into it, and draws after it.
    const held: AcpmuxRow[] = [];
    while (index < rows.length && (rows[index]!.kind !== "user" || isUnsent(rows[index]!))) {
      const row = rows[index++]!;
      (row.kind === "user" ? held : turn).push(row);
    }
    turns.push({ user, turn, held });
  }
  const dated = timestampTurns(
    turns.map(({ user, turn }) => ({ promptAt: user.at, answerAt: [...turn].reverse().find(isAnswer)?.at })),
    now,
    loadedFromStart,
  );
  turns.forEach(({ user, turn, held }, at) => {
    if (dated[at]) out.push({ id: `${DATE}-${user.id}`, version: 1, at: user.at, kind: DATE });
    // Only the last turn can still be running.
    const last = at === turns.length - 1;
    out.push(user, ...shapeTurn(user, turn, expanded, working && last, last), ...held);
  });
  return out;
}

const isAnswer = (row: AcpmuxRow) => row.kind === "assistant";
const isUnsent = (row: AcpmuxRow) => Boolean(row.pending || row.failed);

function shapeTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  expanded: ReadonlySet<string>,
  live: boolean,
  last: boolean,
): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens, under its live status.
  // An earlier turn without a summary ended long ago (a later prompt follows it): it folds as
  // Codex folds a reloaded turn without timing. The last one may only be waiting for its
  // summary, so it draws as it came.
  if (end < 0) return live ? liveTurn(user, turn) : last ? turn : settledWithoutSummary(user, turn, expanded);
  const summary = turn[end]!;
  const body = turn.slice(0, end);
  let final = -1;
  for (let at = body.length - 1; at >= 0; at -= 1)
    if (body[at]!.kind === "assistant") {
      final = at;
      break;
    }
  const answer = final >= 0 ? body[final] : undefined;
  // Work before the answer folds away (all of it, when the turn ended without one); edits
  // also close the turn as their card.
  const work = (final >= 0 ? body.slice(0, final) : body).filter((row) => row.kind !== "typing");
  const edits = work.filter(isEdit);
  const rest = final >= 0 ? body.slice(final + 1) : [];
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
  if (answer) shaped.push(answer);
  shaped.push(...rest, ...editsCard(edits));
  // The footer copies the answer, so it carries the answer's text.
  shaped.push({ ...summary, folded: work.length > 0, text: answer?.text ?? summary.text, version });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  shaped.push(...turn.slice(end + 1));
  return shaped;
}

const VERSION_SPAN = 1_000_000;

/// One edited-files card per turn, as Codex draws it: the turn's edit rows merged into the
/// first one (its id, so View changes still finds the turn), every edit's items in order.
function editsCard(edits: AcpmuxRow[]): AcpmuxRow[] {
  if (edits.length <= 1) return edits;
  const [first] = edits as [AcpmuxRow, ...AcpmuxRow[]];
  return [
    {
      ...first,
      version: edits.reduce((sum, row) => sum + row.version, 0),
      items: edits.flatMap((row) => row.items ?? []),
      toolCount: edits.reduce((sum, row) => sum + (row.toolCount ?? 0), 0),
    },
  ];
}

/// A turn that ended without a summary (history paged in from before acpmux kept one, or a
/// turn a restart cut off): its work folds under "N previous messages", as Codex shows a
/// reloaded turn without timing, and its answer and edits draw after it.
function settledWithoutSummary(user: AcpmuxRow, turn: AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  let final = -1;
  for (let at = rows.length - 1; at >= 0; at -= 1)
    if (rows[at]!.kind === "assistant") {
      final = at;
      break;
    }
  const work = final >= 0 ? rows.slice(0, final) : rows;
  if (work.length === 0) return rows;
  const id = `${WORKED}-${user.id}`;
  const open = expanded.has(id);
  const edits = work.filter(isEdit);
  const previous = work.reduce((count, row) => count + (row.kind === "activity" ? (row.items?.length ?? 1) : 1), 0);
  const version = work.reduce((sum, row) => sum + row.version, 0);
  return [
    { id, version: version * 2 + (open ? 1 : 0), at: user.at, kind: WORKED, previous },
    ...(open ? work.map((row) => ({ ...row, id: isEdit(row) ? `${row.id}${FOLDED}` : row.id, settled: true })) : []),
    ...(final >= 0 ? rows.slice(final) : []),
    ...editsCard(edits),
  ];
}

/// The live status, shaped as the turn will fold when it ends: rows before the latest text are
/// its work, so a turn so far only streaming its answer draws no status (it ends without a
/// fold). The line is timed from the prompt and draws its own clock; while text streams, the
/// clock stops at that text's start, where "Worked for" would time the turn if it ended there.
/// The client's empty "typing" placeholder gives way to it.
function liveTurn(user: AcpmuxRow, turn: AcpmuxRow[]): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  const last = rows.at(-1);
  if (!last) return [{ id: `${THINKING}-${user.id}`, version: 1, at: user.at, kind: THINKING }];
  const answering = last.kind === "assistant";
  if (answering && rows.length === 1) return rows;
  const status: AcpmuxRow = { id: `${WORKING}-${user.id}`, version: 1, at: user.at, kind: WORKING };
  if (answering) Object.assign(status, { version: 2, durationMs: Math.max(0, last.at - user.at) });
  return [status, ...rows];
}

/// A folded copy of an activity row is drawn as tool rows, never as the edited-files card.
export const isFoldedCopy = (row: AcpmuxRow) => row.id.endsWith(FOLDED);
