// Where the rows stay in sight beside the bottom stack (conversation.css `--acpmux-beside-*`). The
// transcript's mask ends the view at the stack's top (`--acpmux-view-foot`), so a row the stack
// reaches over was cut along one straight line across the whole pane, its gutters and the card's
// rounded corners too: a reply's action icons lost their lower half beside the card's corner. The
// ChatGPT and Codex apps keep the row whole there and let the card itself cover it (Lucas,
// 2026-11-17: "this is the issue here, it gets clipped", "where as chatgpt allows it like this").
// So the mask gains a few layers over the stack's reach: each surface's two gutters down to the
// next surface (or its own bottom), and the room outside each top corner's curve. Under a surface's
// glass the rows stay out of sight, as before.

/// One of the stack's surfaces (the tray, the composer card), in the scroller's own coordinates.
export type StackSurface = {
  left: number;
  top: number;
  right: number;
  bottom: number;
  radiusLeft: number;
  radiusRight: number;
  /** The composer's card (`.acpmux-composer-box`), the one surface the dock band arms reach under. */
  card?: boolean;
};

/// How much of the transcript shows in the band at the stack's foot, the composer card and the quiet
/// row under it (dockBand.experiment.ts; Leo, 2026-11-22: "I KINDA HATE HOW MUCH SOLID + BLUR
/// THERE IS AT THE BOTTOM [...] OF THE BOX"). `height` is the scroller's own height: the pane's
/// bottom edge, where the quiet row ends.
export type DockBand = { arm: DockBandArm; height: number };
export type DockBandArm = "shipped" | "frost" | "frost-ramp" | "frost-through";

/// The ramp under the card in `frost-ramp`: the rows fade out over it, into the quiet row.
export const DOCK_BAND_RAMP = 16;

/// The extra mask layers: as many images as sizes and positions, comma-joined, or undefined for none.
export type BesideMask = { images: string; sizes: string; positions: string };

const px = (value: number) => `${Math.round(value * 2) / 2}px`;

/// The mask layers that keep the rows in sight beside `surfaces` (top to bottom, any order in),
/// in a scroller `width` wide. Undefined when nothing is beside them.
export function besideMask(surfaces: readonly StackSurface[], width: number, band?: DockBand): BesideMask | undefined {
  const sorted = [...surfaces].filter((s) => s.right > s.left && s.bottom > s.top).sort((a, b) => a.top - b.top);
  const images: string[] = [];
  const sizes: string[] = [];
  const positions: string[] = [];
  const add = (image: string, x: number, y: number, w: number, h: number) => {
    if (w <= 0.25 || h <= 0.25) return;
    images.push(image);
    sizes.push(`${px(w)} ${px(h)}`);
    positions.push(`${px(x)} ${px(y)}`);
  };
  const solid = "linear-gradient(#000, #000)"; // colour-allow: a mask layer's alpha only, never painted
  // The frost arms: the rows run on under the card, where its own glass frosts them (the one stack
  // material, composerStates.css; no blur of their own), and past its bottom edge as the arm says.
  const underCard = (card: StackSurface, { arm, height }: DockBand) => {
    if (arm === "shipped") return;
    add(solid, card.left, card.top, card.right - card.left, card.bottom - card.top);
    const ramp =
      arm === "frost-ramp"
        ? Math.min(DOCK_BAND_RAMP, height - card.bottom)
        : arm === "frost-through"
          ? height - card.bottom
          : 0;
    add("linear-gradient(#000, transparent)", 0, card.bottom, width, ramp); // colour-allow: a mask ramp, alpha only
  };
  sorted.forEach((surface, at) => {
    const next = sorted[at + 1];
    const previous = sorted[at - 1];
    // A surface's gutters run down to the next surface's top: the next one (the card under the
    // tray) covers its own sides from there.
    const end = next ? Math.min(next.top, surface.bottom) : surface.bottom;
    // A surface tucked under the one above it (the tray's foot under the card's top edge) keeps
    // that one's sides: until its foot, the gutters stay outside it too, and the corner room reaches
    // only to where it begins. A tray wider than the card hides the rows under its foot as well.
    const tucked = previous && previous.bottom > surface.top ? previous : undefined;
    const foot = tucked ? Math.min(tucked.bottom, end) : surface.top;
    if (tucked) {
      add(solid, 0, surface.top, Math.min(surface.left, tucked.left), foot - surface.top);
      add(
        solid,
        Math.max(surface.right, tucked.right),
        surface.top,
        width - Math.max(surface.right, tucked.right),
        foot - surface.top,
      );
    }
    add(solid, 0, foot, surface.left, end - foot);
    add(solid, surface.right, foot, width - surface.right, end - foot);
    const leftRoom = tucked ? Math.max(0, tucked.left - surface.left) : Infinity;
    const rightRoom = tucked ? Math.max(0, surface.right - tucked.right) : Infinity;
    const r = surface.radiusLeft;
    if (r > 0)
      add(
        `radial-gradient(circle ${px(r)} at ${px(r)} ${px(r)}, transparent ${px(r - 0.5)}, #000 ${px(r + 0.5)})`, // colour-allow: mask alpha only
        surface.left,
        surface.top,
        Math.min(r, leftRoom),
        Math.min(r, surface.bottom - surface.top),
      );
    const q = surface.radiusRight;
    if (q > 0) {
      const w = Math.min(q, rightRoom);
      add(
        // The curve's centre is q in from the surface's right edge, so w - q from the piece's left.
        `radial-gradient(circle ${px(q)} at ${px(w - q)} ${px(q)}, transparent ${px(q - 0.5)}, #000 ${px(q + 0.5)})`, // colour-allow: mask alpha only
        surface.right - w,
        surface.top,
        w,
        Math.min(q, surface.bottom - surface.top),
      );
    }
    if (surface.card && band) underCard(surface, band);
  });
  if (!images.length) return undefined;
  return { images: images.join(", "), sizes: sizes.join(", "), positions: positions.join(", ") };
}

/// A box drawn in a band of the stack (the "Needs your input" line's label and Dismiss, a waiting
/// question's card), in the scroller's own coordinates, with its corner radius.
export type BandHole = { left: number; top: number; right: number; bottom: number; radius: number };

type RectEdges = Pick<DOMRect, "left" | "top" | "right" | "bottom">;

/// The portion of `rect` that remains visible inside `clip`, or nothing when the clip removes it.
/// Pending asks use this while their section folds and clips a card whose layout rect still has its
/// old height (useBesideStack.ts).
export function clippedRect(rect: RectEdges, clip: RectEdges): RectEdges | undefined {
  const left = Math.max(rect.left, clip.left);
  const top = Math.max(rect.top, clip.top);
  const right = Math.min(rect.right, clip.right);
  const bottom = Math.min(rect.bottom, clip.bottom);
  return right > left && bottom > top ? { left, top, right, bottom } : undefined;
}

/// A part of the stack with no surface of its own (the asks stack: a quiet label line over a card),
/// from `top` to `bottom` across the pane, and the boxes it draws.
export type StackBand = { top: number; bottom: number; holes: readonly BandHole[] };

/// The mask layers that keep the rows in sight across `band`, everywhere but under its holes and
/// inside their rounded corners (Leo, 2026-11-17: "why do you have the entire row blanked out? don't
/// ever do that. this needs your input dismiss row erases things behind it"). The band is cut into
/// slices at each hole's top and bottom; each slice keeps the room between the holes it crosses.
export function bandMask(band: StackBand, width: number): BesideMask | undefined {
  if (band.bottom - band.top <= 0.25 || width <= 0.25) return undefined;
  const holes = band.holes
    .map((hole) => ({
      left: Math.max(0, hole.left),
      right: Math.min(width, hole.right),
      top: Math.max(band.top, hole.top),
      bottom: Math.min(band.bottom, hole.bottom),
      radius: hole.radius,
    }))
    .filter((hole) => hole.right - hole.left > 0.25 && hole.bottom - hole.top > 0.25);
  const images: string[] = [];
  const sizes: string[] = [];
  const positions: string[] = [];
  const add = (image: string, x: number, y: number, w: number, h: number) => {
    if (w <= 0.25 || h <= 0.25) return;
    images.push(image);
    sizes.push(`${px(w)} ${px(h)}`);
    positions.push(`${px(x)} ${px(y)}`);
  };
  const solid = "linear-gradient(#000, #000)"; // colour-allow: a mask layer's alpha only, never painted
  const edges = [...new Set([band.top, band.bottom, ...holes.flatMap((hole) => [hole.top, hole.bottom])])].sort(
    (a, b) => a - b,
  );
  for (let at = 0; at + 1 < edges.length; at++) {
    const top = edges[at]!;
    const bottom = edges[at + 1]!;
    const crossing = holes.filter((hole) => hole.top < bottom && hole.bottom > top).sort((a, b) => a.left - b.left);
    let x = 0;
    for (const hole of crossing) {
      add(solid, x, top, hole.left - x, bottom - top);
      x = Math.max(x, hole.right);
    }
    add(solid, x, top, width - x, bottom - top);
  }
  // The room outside each hole's four rounded corners.
  for (const hole of holes) {
    const r = Math.min(hole.radius, (hole.right - hole.left) / 2, (hole.bottom - hole.top) / 2);
    if (r <= 0.5) continue;
    const corner = (cx: number, cy: number) =>
      `radial-gradient(circle ${px(r)} at ${px(cx)} ${px(cy)}, transparent ${px(r - 0.5)}, #000 ${px(r + 0.5)})`; // colour-allow: mask alpha only
    add(corner(r, r), hole.left, hole.top, r, r);
    add(corner(0, r), hole.right - r, hole.top, r, r);
    add(corner(r, 0), hole.left, hole.bottom - r, r, r);
    add(corner(0, 0), hole.right - r, hole.bottom - r, r, r);
  }
  if (!images.length) return undefined;
  return { images: images.join(", "), sizes: sizes.join(", "), positions: positions.join(", ") };
}

/// Two sets of mask layers as one (either may be absent).
export function joinMasks(a: BesideMask | undefined, b: BesideMask | undefined): BesideMask | undefined {
  if (!a) return b;
  if (!b) return a;
  return {
    images: `${a.images}, ${b.images}`,
    sizes: `${a.sizes}, ${b.sizes}`,
    positions: `${a.positions}, ${b.positions}`,
  };
}
