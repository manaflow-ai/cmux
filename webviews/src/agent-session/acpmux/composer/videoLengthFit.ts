// A video tile's length badge sits in its bottom-right corner on one line, or not at all (Leo,
// 2026-11-11, of a 36 px composer chip whose "0:32" broke onto two lines over its play glyph: "this
// preview, the time is on the wrong place ... we should never be able to see this"). Every video
// tile draws it: the composer's strip chip and the chip placed in the text (VideoAttachmentTile.tsx),
// a sent prompt's tile (conversation/SentVideoTile.tsx) and a queued prompt's (QueuedImages.tsx).
//
// The rule is the badge's own box, measured where it is drawn, so it holds for any tile size,
// interface scale and length ("0:32", "12:34", "1:02:03"): the badge shows only when it lies wholly
// inside the tile, LENGTH_EDGE in from each side, and clear of the tile's play glyph. Otherwise the
// tile wears `data-length-clipped` and its CSS hides the length (a queued tile, whose corner chip is
// the glyph and the length together, keeps its glyph). The length stays in the tile's label and
// tooltip. On a tile under the glyph's and the badge's height together that means a narrow tile
// shows no length; the gallery's `agent-pane.video-length-badge` compares this with the other looks.
import { type RefObject, useLayoutEffect } from "react";

/// The least room between the badge and the tile's edge, in px.
export const LENGTH_EDGE = 2;

/// A box in one coordinate space, as `getBoundingClientRect` gives it.
export type Box = { left: number; top: number; right: number; bottom: number };

/// Whether a length badge at `badge` reads in a tile at `tile`: wholly inside it, LENGTH_EDGE in, and
/// clear of the play glyph at `glyph` (a tile whose badge carries its glyph has none apart).
export function lengthFits(tile: Box, badge: Box, glyph?: Box): boolean {
  // Half a pixel of rounding: a badge drawn at 4 px in measures 3.99 at some scales.
  const slack = 0.5;
  const inside =
    badge.left >= tile.left + LENGTH_EDGE - slack &&
    badge.top >= tile.top + LENGTH_EDGE - slack &&
    badge.right <= tile.right - LENGTH_EDGE + slack &&
    badge.bottom <= tile.bottom - LENGTH_EDGE + slack;
  if (!inside) return false;
  if (!glyph) return true;
  return (
    badge.left >= glyph.right - slack ||
    badge.right <= glyph.left + slack ||
    badge.top >= glyph.bottom - slack ||
    badge.bottom <= glyph.top + slack
  );
}

/// The badge's mark: the element whose box is measured.
export const LENGTH_BADGE = "data-video-length";
/// The play glyph's mark (or what stands in its place, a tile's "can't play" note).
export const LENGTH_GLYPH = "data-video-glyph";
/// Set on the tile when its length does not fit.
export const LENGTH_CLIPPED = "data-length-clipped";

/// Measures `tile`'s badge against it and its glyph, before paint and again whenever the tile's size
/// changes (its poster loading, a narrower bubble), and marks the tile when the length does not fit.
/// `key` is what the badge says: a new length is measured again. Writes the attribute itself, so no
/// render follows a measure.
export function useVideoLengthFit(tile: RefObject<HTMLElement | null>, key: string | undefined): void {
  useLayoutEffect(() => {
    const element = tile.current;
    if (!element || !key) return;
    const measure = () => {
      const badge = element.querySelector(`[${LENGTH_BADGE}]`);
      // Measured as it draws with its length: unmarked first, then marked again if it does not fit.
      element.removeAttribute(LENGTH_CLIPPED);
      if (!badge) return;
      const box = element.getBoundingClientRect();
      // Not laid out (a hidden pane, a test's document): nothing to measure yet.
      if (box.width === 0 || box.height === 0) return;
      const glyph = element.querySelector(`[${LENGTH_GLYPH}]`)?.getBoundingClientRect();
      if (!lengthFits(box, badge.getBoundingClientRect(), glyph)) element.setAttribute(LENGTH_CLIPPED, "");
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const sizes = new ResizeObserver(measure);
    sizes.observe(element);
    // The badge's font may land after the first measure.
    let live = true;
    void document.fonts?.ready.then(() => live && measure());
    return () => {
      live = false;
      sizes.disconnect();
    };
  }, [tile, key]);
}
