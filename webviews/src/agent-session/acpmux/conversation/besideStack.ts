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
