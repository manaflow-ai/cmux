// The transcript as Codex draws a turn: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After codex-atlas-clone's
// derive.ts (`deriveTurn`, `formatDuration`).
import type { AcpmuxRow } from "../model";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
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

/// "Worked for 15s · 2 tool calls". Codex counts the time to the final answer's first text,
/// not to the turn's end; a summary without a start time has only its count.
export function workedLabel(row: AcpmuxRow): string {
  const calls = row.toolCount ? toolCalls(row.toolCount) : "";
  if (row.durationMs === undefined) return calls || toolCalls(0);
  const time = formatDuration(row.durationMs);
  const lead = row.status === "cancelled" ? `You stopped after ${time}` : `Worked for ${time}`;
  return calls ? `${lead} · ${calls}` : lead;
}

const isEdit = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");

/// The rows to draw. `expanded` holds the ids of open disclosures; `working` says the last
/// turn is still running (the snapshot's `isWorking`).
export function turnView(rows: readonly AcpmuxRow[], expanded: ReadonlySet<string>, working = false): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  let index = 0;
  // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are.
  while (index < rows.length && rows[index]!.kind !== "user") out.push(rows[index++]!);
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
    const live = working && index >= rows.length;
    out.push(user, ...shapeTurn(user, turn, expanded, live), ...held);
  }
  return out;
}

const isUnsent = (row: AcpmuxRow) => Boolean(row.pending || row.failed);

function shapeTurn(user: AcpmuxRow, turn: AcpmuxRow[], expanded: ReadonlySet<string>, live: boolean): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens, under its live status.
  if (end < 0) return live ? liveTurn(user, turn) : turn;
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
  shaped.push(...rest, ...edits);
  // The footer copies the answer, so it carries the answer's text.
  shaped.push({ ...summary, folded: work.length > 0, text: answer?.text ?? summary.text, version });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  shaped.push(...turn.slice(end + 1));
  return shaped;
}

const VERSION_SPAN = 1_000_000;

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
