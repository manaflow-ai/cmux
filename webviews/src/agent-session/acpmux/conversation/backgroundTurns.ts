// Turns the agent ran on its own (acpmux `background_turn` records): a background task or subagent
// finished, a scheduled wakeup or /loop tick, a hook. One with nothing new to tell draws as one
// muted line that opens on click, and never as a message (Leo, on a chat message that said only
// "Nothing new for you yet.": "why do you guys keep sending me this/get pinged to send this").
// acpmux decides `quiet`; this pass never decides it again. A turn the person started, and a
// background turn acpmux did not call quiet, draw exactly as before.
//
// acpmux also weighs the task whose end started the turn, from the task's own event (Leo,
// 2026-11-03: "there's like... background tasks worth responding to and not worth responding
// to"; acpmux hub/background_cause.rs): a step, an interim stop or a monitor tick (`silent`) draws
// no line; a final result (`result`) goes onto the call that started the task, marked new; a
// failure always draws. Whatever the turn said is the agent's own message, never the call's
// (direct.ts `settleReaction`). backgroundReaction.experiment.ts holds the looks.
import { experimentArm } from "../../../experiments/experiment";
import type { AcpmuxBackgroundCause, AcpmuxBackgroundTurn, AcpmuxBackgroundWeight, AcpmuxRow } from "../model";
import type { Folds } from "./viewFolds";
import type { Translate } from "../i18n";
import { backgroundReactionLook, reactsOnCall } from "./backgroundReaction.experiment";
import { backgroundTurnLook, backgroundTurnsInline } from "./backgroundTurnLook.experiment";

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
    ...(msg.state === "started" && backgroundCause(msg.cause)),
  };
}

const WEIGHTS: readonly AcpmuxBackgroundWeight[] = ["silent", "result", "failure"];
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// A started record's `cause`, as `{ cause }`, or nothing for none or a malformed one.
function backgroundCause(value: unknown): { cause: AcpmuxBackgroundCause } | undefined {
  if (!value || typeof value !== "object") return undefined;
  const cause = value as Record<string, unknown>;
  const weight = WEIGHTS.find((weight) => weight === cause.weight);
  const kind = text(cause.kind);
  const status = text(cause.status);
  if (!weight || !kind || !status) return undefined;
  const origin = text(cause.origin);
  const summary = text(cause.summary);
  return { cause: { kind, status, weight, ...(origin && { origin }), ...(summary && { summary }) } };
}

/// How much the task whose end started this turn is worth, in the arms that read it; undefined in
/// the folded-run arm and for a turn acpmux did not weigh (a log from before it did).
export function backgroundWeight(turn: AcpmuxBackgroundTurn): AcpmuxBackgroundWeight | undefined {
  if (!turn.cause || experimentArm(backgroundReactionLook) === "fold") return undefined;
  return turn.cause.weight;
}

/// Whether a background turn's line stands for its rows: while it runs, and once it ended quiet.
/// One that ended with something to say draws its rows as they came, with no line.
/// A silent one always folds: whatever it said goes with its task's call.
/// One whose call took its task's end and that said something (`ownTurn`) never folds, whatever its
/// weight: its rows are the agent's own turn.
export const foldsBackground = (row: AcpmuxRow): boolean =>
  row.kind === BACKGROUND_TURN &&
  row.background !== undefined &&
  row.background.ownTurn !== true &&
  (row.background.running || row.background.quiet === true || backgroundWeight(row.background) === "silent");

/// Whether a background turn's reply says nothing: only dots, middle dots, bullets or an ellipsis
/// ("·", ".", "…"), which Claude answers a task's end with (Leo, 2026-11-02: "why do you still do
/// these"). Such a reply is never the agent's own turn: its task's call keeps its mark and the turn
/// folds as quiet (direct.ts `settleReaction`).
export function saysNothing(reply: string): boolean {
  return /^[\s.·•…]*$/u.test(reply);
}

/// Whether a background turn draws its line: one that folds, while it runs or once it has a row of
/// its own to open to. A quiet one that ended with none has nothing to show (Leo, 2026-11-03: "these
/// background updates don't really expand out to anything? idk what those are even for").
/// Weighed by acpmux: a turn whose call carries it (`attached`, in the arms that put it there) draws
/// no line; a silent one draws none either, unless it ended with something to say and no call took
/// it, so its words keep a line to open; a result names its task even with no row to open; a
/// failure always draws.
export function drawsBackgroundLine(row: AcpmuxRow): boolean {
  if (!foldsBackground(row)) return false;
  const turn = row.background!;
  const weight = backgroundWeight(turn);
  // Inline (backgroundTurnLook.experiment.ts), only a line that names its task stays: its failure
  // or its result. "Background update", "Scheduled check" and the rest draw nothing; the turn's
  // tool calls draw where they ran (`hiddenInBackground`).
  if (backgroundTurnsInline(experimentArm(backgroundTurnLook)) && weight !== "failure" && weight !== "result")
    return false;
  if (weight !== "failure" && turn.attached && reactsOnCall(experimentArm(backgroundReactionLook))) return false;
  switch (weight) {
    case "silent":
      return !turn.running && turn.quiet !== true && turn.hasRows === true;
    case "result":
    case "failure":
      return true;
    default:
      return turn.running || turn.hasRows === true;
  }
}

/// Whether a background turn that does not fold still draws its line, over its rows: a failure
/// that ended with something to say keeps its named line, so a long reply never hides what failed
/// (cmux#33319). Its rows draw as they came under it; the line opens nothing.
export function headsBackground(row: AcpmuxRow): boolean {
  if (row.kind !== BACKGROUND_TURN || !row.background || foldsBackground(row)) return false;
  return backgroundWeight(row.background) === "failure";
}

/// Update the owner set while a caller is already walking the transcript. Keeping this mutation
/// beside that walk avoids a second O(rows) pass on every streamed snapshot.
export function collectFoldedBackgroundId(closed: Set<string>, row: AcpmuxRow, expanded: Folds): void {
  if (row.kind !== BACKGROUND_TURN || !row.background) return;
  // Inline there is no line to open: a running or quiet turn's reply stays hidden whatever `expanded`
  // holds, and any other turn's reply draws, as a silent one that ended with something to say has no
  // line left to open to it.
  const inline = backgroundTurnsInline(experimentArm(backgroundTurnLook));
  const hides = inline
    ? foldsBackground(row) && (row.background.running || row.background.quiet === true)
    : foldsBackground(row) && !expanded.has(row.id);
  if (hides) closed.add(row.background.id);
  else closed.delete(row.background.id);
}

/// `rows` with each background turn's line and rows as they draw: a folding line stands alone
/// while closed and its rows follow it while open (`expanded` holds its id); a line that does not
/// fold draws nothing and its rows stay; a folding line with nothing to open to draws nothing. Without a background turn, `rows` itself.
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
  const inline = backgroundTurnsInline(experimentArm(backgroundTurnLook));
  return rows.filter((row) => {
    // A line that draws nothing still draws while open (Find opened it), so it can close again.
    if (row.kind === BACKGROUND_TURN)
      return (
        drawsBackgroundLine(row) ||
        headsBackground(row) ||
        (!inline && expanded.has(row.id) && foldsBackground(row) && row.background?.hasRows === true)
      );
    return !hiddenInBackground(row, folding);
  });
}

/// Whether `row` is hidden behind its background turn (`folded`, from `foldedBackgroundIds`). With
/// one line per turn, every row of a closed one is. Inline (Leo, 2026-11-11: "it should maybe
/// arguably just be treated like a normal tool call"), a folding turn's tool calls draw where they
/// ran, as any other call does, and only its reply stays hidden: a turn acpmux called quiet has
/// nothing to tell (Leo: "why do you guys keep sending me this/get pinged to send this"), and a
/// running one's reply waits until acpmux says whether it is.
export function hiddenInBackground(row: AcpmuxRow, folded: ReadonlySet<string>): boolean {
  if (row.inBackground === undefined || !folded.has(row.inBackground)) return false;
  return row.kind === "assistant" || !backgroundTurnsInline(experimentArm(backgroundTurnLook));
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
/// Weighed, a failure says so and a result names its task in the notification's own words.
export function backgroundTurnLabel(t: Translate, turn: AcpmuxBackgroundTurn): string {
  const weight = backgroundWeight(turn);
  if (weight === "failure") return turn.cause?.summary ?? t("backgroundTurn.failed");
  if (weight === "result" && turn.cause?.summary) return turn.cause.summary;
  if (turn.trigger === "task_notification") return t("backgroundTurn.task");
  if (turn.trigger === "scheduled") return t("backgroundTurn.scheduled");
  return t("backgroundTurn.other");
}
