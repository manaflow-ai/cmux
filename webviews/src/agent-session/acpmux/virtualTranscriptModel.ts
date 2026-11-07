import { type AcpmuxRow } from "./model";
import { type ReferenceScope } from "./conversation/bareReferences";
import { isEditRow } from "./turnChanges/sessionRows";
import { ACTIVITY_LINE, THINKING, WORKING } from "./conversation/turns";
import { workEnds } from "./conversation/waterfallSpans";

export const NO_ROWS: readonly AcpmuxRow[] = [];

/// RowFrame redraws only when a prop it or its row's renderer reads changed. `children` is left out:
/// it is a new element every render, built from `row` and the content props passed beside it
/// (`contentType` and the rest), so comparing every other prop is enough. The callbacks are stable
/// across snapshots (VirtualTranscript and the pane hold them), so a streaming snapshot that changes
/// only the latest row leaves every other mounted row alone.
export function sameReferenceScope(previous: ReferenceScope | undefined, next: ReferenceScope | undefined): boolean {
  if (previous === next) return true;
  if (!previous || !next || previous.at !== next.at) return false;
  if (previous.evidence.linked.length !== next.evidence.linked.length) return false;
  if (!previous.evidence.linked.every((repo, index) => repo === next.evidence.linked[index])) return false;
  const sameMap = <K, V>(a: ReadonlyMap<K, V>, b: ReadonlyMap<K, V>, valueEqual: (left: V, right: V) => boolean) => {
    if (a.size !== b.size) return false;
    for (const [key, value] of a) {
      const other = b.get(key);
      if (other === undefined || !valueEqual(value, other)) return false;
    }
    return true;
  };
  const sameMentions = (
    left: readonly { at: number; repo: string }[],
    right: readonly { at: number; repo: string }[],
  ) =>
    left.length === right.length &&
    left.every((mention, index) => mention.at === right[index]?.at && mention.repo === right[index]?.repo);
  return (
    sameMap(previous.evidence.mentions, next.evidence.mentions, sameMentions) &&
    sameMap(previous.turn, next.turn, (left, right) => left === right)
  );
}

/// Whether two rows hold the same value in every own field (one level deep).
function sameFields(previous: AcpmuxRow, next: AcpmuxRow): boolean {
  if (previous === next) return true;
  const before = previous as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  return keys.length === Object.keys(before).length && keys.every((key) => Object.is(before[key], after[key]));
}

/// Whether a row draws the same: renderers use id and version as their draw identity, so a clone of
/// an unchanged row (snapshot rebuilding clones them when a prompt is sent) draws the same. The
/// frame's own flags (`below`, `ended`) are compared too, as they are read outside the renderer.
function sameRowDraw(before: AcpmuxRow, after: AcpmuxRow): boolean {
  // The running turn's live, working and activity lines are drawn by turns.ts on every snapshot
  // with a version that does not cover all they say (the call in flight, who a send goes to, its
  // time, the clock offset): those are in their fields, so they redraw whenever a field changes.
  if (after.kind === THINKING || after.kind === WORKING || after.kind === ACTIVITY_LINE)
    return sameFields(before, after);
  return (
    before.id === after.id &&
    before.version === after.version &&
    before.below === after.below &&
    before.ended === after.ended &&
    // A turn footer's Timeline also redraws when a background shell ends after the turn, which
    // leaves its version as it was (conversation/waterfallSpans.ts workEnds, cached per array).
    (after.kind !== "turnSummary" || workEnds(before.turnWork) === workEnds(after.turnWork))
  );
}

export function sameRowFrame(previous: Record<string, unknown>, next: Record<string, unknown>): boolean {
  const keys = Object.keys(next);
  if (keys.length !== Object.keys(previous).length) return false;
  return keys.every((key) => {
    if (key === "children") return true;
    // Snapshot rebuilding can clone unchanged rows when a prompt is sent; comparing the object here
    // made every mounted frame repaint on that send even though its content had not changed.
    if (key === "row") return sameRowDraw(previous.row as AcpmuxRow, next.row as AcpmuxRow);
    if (key === "referenceScope")
      return sameReferenceScope(
        previous.referenceScope as ReferenceScope | undefined,
        next.referenceScope as ReferenceScope | undefined,
      );
    return Object.is(previous[key], next[key]);
  });
}

export const rowKind = (row: AcpmuxRow) => (isEditRow(row) ? "editedFiles" : row.kind);

/// Small layout changes arrive constantly while a reply streams. Treat the bottom as a short
/// resting zone so every token does not write a new fractional scroll offset (and make the thumb
/// visibly twitch at the same cadence). A meaningful displacement still corrects immediately.
/// Four CSS pixels is below the visual rhythm of a transcript line, so the reader gets a little
/// give while a burst is measured and one correction when that burst is meaningful.
export const FOLLOW_BOTTOM_DEADBAND_PX = 4;

/// A scroll that rests this long is where the chat reopens (cx-6bgzj), reported once, not per frame.
export const SCROLL_ANCHOR_SETTLE_MS = 400;
