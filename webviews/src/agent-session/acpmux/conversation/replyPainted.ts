// Whether the chat on screen paints the final reply of the turn that just ended (Leo, 2026-11-12:
// "evidently the GUI is not, like, moving properly. Well, you should be able to detect that the
// messages aren't coming out from the coordinator"). repliesDrawn.ts proves the reply row is built
// (reducer and fold, on the real log); this reads the painted page: the reply's row must be in the
// document, as tall as a line, opaque, unclipped and in the view the reader follows. A reply that is
// not is recorded as `reply-unpainted` in the flicker ring file (flickerLog.ts), with why, so the
// app's own log says when it happened, not Leo.
import type { AcpmuxRow } from "../model";

/// Why the reply is not painted: no row node (`missing`), a node with no text (`empty`) or no
/// height (`flat`), faded out (`transparent`), `visibility: hidden` (`hidden`), a clip left on it or
/// a row above it (`clipped`), or placed off the followed view (`outside`).
export type Unpainted = "missing" | "empty" | "flat" | "transparent" | "hidden" | "clipped" | "outside";

/// How long after the last change (rows, working) the page has to settle before the check: past a
/// turn end's fold, the reveal's drain and the load fade (each well under a second).
export const REPLY_SETTLE_MS = 2500;
/// Below this the reply reads as gone (a fade held at its start, an opacity left at 0).
const MIN_OPACITY = 0.5;
/// How far back from the end a turn's final reply can sit: its footer, a notice, a held line.
const TAIL_ROWS = 8;

/// The id of the ended turn's final reply in the drawn rows: the last assistant row of the last
/// turn, nearer the end than the person's last prompt. Undefined when that turn ended with no words
/// of its own (its work alone, folded by design) or the reply folds into a note (`foldedReply`).
export function finalReplyId(rows: readonly AcpmuxRow[]): string | undefined {
  for (let index = rows.length - 1; index >= Math.max(0, rows.length - TAIL_ROWS); index -= 1) {
    const row = rows[index]!;
    if (row.kind === "user") return undefined;
    if (row.kind !== "assistant" || row.foldedReply) continue;
    return typeof row.text === "string" && row.text.trim() ? row.id : undefined;
  }
  return undefined;
}

type Box = { top: number; bottom: number };

/// What keeps `node` (the reply's row) from being read in `view` (the scroller's box), up to `root`
/// (the transcript's own element); undefined when it is painted.
export function replyUnpainted(node: HTMLElement | null, root: HTMLElement, view: Box): Unpainted | undefined {
  if (!node || !node.isConnected) return "missing";
  if (!node.textContent?.trim()) return "empty";
  const box = node.getBoundingClientRect();
  if (box.height < 1) return "flat";
  const style = (element: Element) => element.ownerDocument.defaultView!.getComputedStyle(element);
  if (style(node).visibility === "hidden") return "hidden";
  let opacity = 1;
  for (let at: Element | null = node; at; at = at === root ? null : at.parentElement) {
    const look = style(at);
    opacity *= Number.parseFloat(look.opacity || "1");
    if (look.display === "none") return "hidden";
    if (look.clipPath && look.clipPath !== "none") return "clipped";
  }
  if (opacity < MIN_OPACITY) return "transparent";
  if (box.bottom <= view.top || box.top >= view.bottom) return "outside";
  return undefined;
}
