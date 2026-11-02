// Turns the agent ran on its own (acpmux `background_turn` records): a background task or subagent
// finished, a scheduled wakeup or /loop tick, a hook. One with nothing new to tell draws as one
// muted line that opens on click, and never as a message (Leo, on a chat message that said only
// "Nothing new for you yet.": "why do you guys keep sending me this/get pinged to send this").
// acpmux decides `quiet`; this pass never decides it again. A turn the person started, and a
// background turn acpmux did not call quiet, draw exactly as before.
import type { AcpmuxBackgroundTurn, AcpmuxRow } from "../model";
import type { Folds } from "./viewFolds";
import type { Translate } from "../i18n";

/// The line of one background turn (direct.ts makes it at the turn's started record). Its rows are
/// the rows an event between its started and ended record made (`inBackground`).
export const BACKGROUND_TURN = "backgroundTurn";

export const backgroundTurnRowId = (id: string) => `${BACKGROUND_TURN}-${id}`;

/// What a `background_turn` record says, or undefined for a malformed one.
export function backgroundTurnRecord(
  msg: Record<string, unknown> | undefined,
): (AcpmuxBackgroundTurn & { state: "started" | "ended" }) | undefined {
  if (!msg || typeof msg.id !== "string" || !msg.id) return undefined;
  if (msg.state !== "started" && msg.state !== "ended") return undefined;
  const trigger = typeof msg.trigger === "string" ? msg.trigger : "system";
  return {
    state: msg.state,
    id: msg.id,
    trigger,
    running: msg.state === "started",
    ...(msg.state === "ended" && { quiet: msg.quiet === true }),
    ...(msg.state === "ended" && typeof msg.reason === "string" && { reason: msg.reason }),
  };
}

/// Whether a background turn's line stands for its rows: while it runs, and once it ended quiet.
/// One that ended with something to say draws its rows as they came, with no line.
export const foldsBackground = (row: AcpmuxRow): boolean =>
  row.kind === BACKGROUND_TURN &&
  row.background !== undefined &&
  (row.background.running || row.background.quiet === true);

/// Update the owner set while a caller is already walking the transcript. Keeping this mutation
/// beside that walk avoids a second O(rows) pass on every streamed snapshot.
export function collectFoldedBackgroundId(closed: Set<string>, row: AcpmuxRow, expanded: Folds): void {
  if (row.kind !== BACKGROUND_TURN || !row.background) return;
  if (foldsBackground(row) && !expanded.has(row.id)) closed.add(row.background.id);
  else closed.delete(row.background.id);
}

/// `rows` with each background turn's line and rows as they draw: a folding line stands alone
/// while closed and its rows follow it while open (`expanded` holds its id); a line that does not
/// fold draws nothing and its rows stay. Without a background turn, `rows` itself.
/** IDs whose owner background line currently hides its rows. Kept separately from the
 * current prompt: a background subagent may end after a newer user prompt, but its done line
 * still belongs behind the original background line. A later owner update wins for an ID.
 */
export function foldedBackgroundIds(rows: readonly AcpmuxRow[], expanded: Folds): Set<string> {
  const closed = new Set<string>();
  for (const row of rows) collectFoldedBackgroundId(closed, row, expanded);
  return closed;
}

export function foldBackgroundTurns(rows: AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  if (!rows.some((row) => row.kind === BACKGROUND_TURN)) return rows;
  const folding = foldedBackgroundIds(rows, expanded);
  return rows.filter((row) => {
    if (row.kind === BACKGROUND_TURN) return foldsBackground(row);
    return !(row.inBackground !== undefined && folding.has(row.inBackground));
  });
}

/// The ids of the open background lines in `rows[start..end)`, which a cached turn compares.
export function openBackgroundTurns(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  let open = "";
  for (let at = start; at < end; at += 1) {
    const row = rows[at]!;
    if (row.kind === BACKGROUND_TURN && expanded.has(row.id)) open += `${row.id} `;
  }
  return open;
}

/// The line's words: what started the turn.
export function backgroundTurnLabel(t: Translate, turn: AcpmuxBackgroundTurn): string {
  if (turn.trigger === "task_notification") return t("backgroundTurn.task");
  if (turn.trigger === "scheduled") return t("backgroundTurn.scheduled");
  return t("backgroundTurn.other");
}
