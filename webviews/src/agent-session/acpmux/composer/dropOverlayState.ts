// The drop overlay's state (Lawrence 2026-10-21: "make sure dropping files/photos has super beautiful
// well designed responsive indicator too"; Leo 2026-10-23: "i think we could do claude + themed
// ring?"). A drag with files over the agent pane rings the composer's box in the accent
// (composer/DropOverlay.tsx, dropOverlay.css): faint over the pane, full over the chat, the danger
// color with its reason when the chat cannot take what is dragged; on a drop it fades as the files
// become chips. The state comes from the one document-level drop contract (attachments.ts
// installFileDropLifecycle), so the overlay and the intake never disagree about a drag.
import { dragHasFiles } from "../attachments";

/// What the dragged files are, for the overlay's hint.
export type DragKind = "photos" | "pdfs" | "files";

/// What a drag holds, as far as the engine shows it before the drop: during a drag the page sees
/// each item's kind and MIME type, never its name or bytes. `count` 0: the engine shows no items
/// (the hint is left out).
export type DragSummary = {
  count: number;
  kind: DragKind;
  /// The chat cannot take any of it (images to an agent without image input): the drop is refused.
  refused: boolean;
};

/// The overlay's phase. `armed`: a file drag is over the pane but not over the chat itself (the
/// header, the session list); `over`: over the chat, where a drop attaches; `refused`: over the
/// chat with nothing it can take; `landing`: the drop happened and the ring fades, then hides.
export type DropPhase = "hidden" | "armed" | "over" | "refused" | "landing";

export type DropOverlayState = { phase: "hidden" } | { phase: Exclude<DropPhase, "hidden">; summary: DragSummary };

export const HIDDEN_DROP: DropOverlayState = { phase: "hidden" };

type ItemLike = { kind: string; type: string };
type TransferLike = { types: readonly string[] | DOMStringList; items?: ArrayLike<ItemLike> | null };

/// The files of a drag, summarized; undefined when it carries no files (dragged text or a link,
/// which the overlay leaves to the field under the pointer).
export function summarizeDrag(transfer: TransferLike | null, allowImages: boolean): DragSummary | undefined {
  if (!dragHasFiles(transfer as DataTransfer | null)) return undefined;
  const items = transfer?.items ? Array.from(transfer.items).filter((item) => item.kind === "file") : [];
  const types = items.map((item) => item.type.toLowerCase());
  const known = types.length > 0 && types.every(Boolean);
  const kind: DragKind =
    known && types.every((type) => type.startsWith("image/"))
      ? "photos"
      : known && types.every((type) => type === "application/pdf")
        ? "pdfs"
        : "files";
  return { count: items.length, kind, refused: !allowImages && kind === "photos" };
}

/// The overlay's state for a drag at a point: `summary` of what it holds, `inside` whether the
/// pointer is over the chat.
export function dragOverlayState(summary: DragSummary | undefined, inside: boolean): DropOverlayState {
  if (!summary) return HIDDEN_DROP;
  if (!inside) return { phase: "armed", summary };
  return { phase: summary.refused ? "refused" : "over", summary };
}

/// Two states draw the same: the overlay re-renders only when one of these changes, not on every
/// `dragover` (about 20 a second while the pointer moves).
export function sameDropState(a: DropOverlayState, b: DropOverlayState): boolean {
  if (a.phase !== b.phase) return false;
  if (a.phase === "hidden" || b.phase === "hidden") return true;
  return (
    a.summary.count === b.summary.count && a.summary.kind === b.summary.kind && a.summary.refused === b.summary.refused
  );
}

/// Whether a point is over `zone`'s box (the chat column), in client coordinates.
export function pointInside(zone: Element | null | undefined, x: number, y: number): boolean {
  if (!zone) return true;
  const box = zone.getBoundingClientRect();
  if (box.width === 0 && box.height === 0) return true;
  return x >= box.left && x <= box.right && y >= box.top && y <= box.bottom;
}

/// The overlay's step for one drag event (the drop contract's `onActiveChange`): the next state,
/// and the event's `dropEffect`: `copy` for a drag the chat takes, so the pointer carries the system's
/// copy + (Leo 2026-10-23: "claude has blue ring and the apple +"), `none` for a refused one, so the
/// pointer shows no drop and the drop never fires. `zone` is the chat column; a point outside it arms the overlay only.
export function stepDropOverlay(
  current: DropOverlayState,
  active: boolean,
  event: DragEvent | undefined,
  allowImages: boolean,
  zone: Element | null | undefined,
): DropOverlayState {
  if (!active) return current.phase === "landing" ? current : HIDDEN_DROP;
  const summary = summarizeDrag(event?.dataTransfer ?? null, allowImages);
  // A dragenter's point is where the drag came in; a dragover's is the pointer.
  const inside = event ? pointInside(zone, event.clientX, event.clientY) : true;
  const next = dragOverlayState(summary, inside);
  if (event?.dataTransfer) event.dataTransfer.dropEffect = next.phase === "refused" ? "none" : "copy";
  return sameDropState(current, next) ? current : next;
}

/// The state after a drop: the ring fades as the files land, carrying what the drag showed.
export function landDropOverlay(current: DropOverlayState, files: readonly File[]): DropOverlayState {
  const summary =
    current.phase === "hidden"
      ? summarizeFiles(files)
      : { ...current.summary, count: files.length || current.summary.count };
  return { phase: "landing", summary };
}

function summarizeFiles(files: readonly File[]): DragSummary {
  const types = files.map((file) => file.type.toLowerCase());
  const kind: DragKind =
    types.length && types.every((type) => type.startsWith("image/"))
      ? "photos"
      : types.length && types.every((type) => type === "application/pdf")
        ? "pdfs"
        : "files";
  return { count: files.length, kind, refused: false };
}
