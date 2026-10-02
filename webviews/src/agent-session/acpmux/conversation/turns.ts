// The transcript as Codex draws a turn: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After codex-atlas-clone's
// derive.ts (`deriveTurn`, `formatDuration`).
import type { AcpmuxRow } from "../model";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
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

export const toolCalls = (count = 0) => count === 1 ? "1 tool call" : `${count} tool calls`;

/// "Worked for 15s · 2 tool calls". Codex counts the time to the final answer's first text,
/// not to the turn's end; a summary without a start time has only its count.
export function workedLabel(row: AcpmuxRow): string {
  const calls = row.toolCount ? toolCalls(row.toolCount) : "";
  if (row.durationMs === undefined) return calls || toolCalls(0);
  const time = formatDuration(row.durationMs);
  const lead = row.status === "cancelled" ? `You stopped after ${time}` : `Worked for ${time}`;
  return calls ? `${lead} · ${calls}` : lead;
}

const isEdit = (row: AcpmuxRow) => row.kind === "activity" && (row.items ?? []).some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");

/// The rows to draw. `expanded` holds the ids of open disclosures.
export function turnView(rows: readonly AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  let index = 0;
  // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are.
  while (index < rows.length && rows[index]!.kind !== "user") out.push(rows[index++]!);
  while (index < rows.length) {
    const user = rows[index++]!;
    const turn: AcpmuxRow[] = [];
    while (index < rows.length && rows[index]!.kind !== "user") turn.push(rows[index++]!);
    out.push(user, ...shapeTurn(user, turn, expanded));
  }
  return out;
}

function shapeTurn(user: AcpmuxRow, turn: AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens.
  if (end < 0) return turn;
  const summary = turn[end]!;
  const body = turn.slice(0, end);
  let final = -1;
  for (let at = body.length - 1; at >= 0; at -= 1) if (body[at]!.kind === "assistant") { final = at; break; }
  const answer = final >= 0 ? body[final] : undefined;
  // Work before the answer folds away (all of it, when the turn ended without one); edits
  // also close the turn as their card.
  const work = (final >= 0 ? body.slice(0, final) : body).filter((row) => row.kind !== "typing");
  const edits = work.filter(isEdit);
  const rest = final >= 0 ? body.slice(final + 1) : [];
  const shaped: AcpmuxRow[] = [];
  if (work.length) {
    const id = `${WORKED}-${user.id}`;
    const open = expanded.has(id);
    shaped.push({ id, version: open ? 2 : 1, at: user.at, kind: WORKED, status: summary.status, toolCount: summary.toolCount, durationMs: answer ? Math.max(0, answer.at - user.at) : summary.durationMs ?? Math.max(0, summary.at - user.at) });
    if (open) shaped.push(...work.map((row) => isEdit(row) ? { ...row, id: `${row.id}${FOLDED}` } : row));
  }
  if (answer) shaped.push(answer);
  shaped.push(...rest, ...edits);
  // The footer copies the answer, so it carries the answer's text.
  const footer = { ...summary, folded: work.length > 0 };
  shaped.push(answer ? { ...footer, text: answer.text, version: summary.version + answer.version } : footer);
  return shaped;
}

/// A folded copy of an activity row is drawn as tool rows, never as the edited-files card.
export const isFoldedCopy = (row: AcpmuxRow) => row.id.endsWith(FOLDED);
