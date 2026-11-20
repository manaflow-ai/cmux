// The outline of a popover whose arrow is a smooth notch in its own edge (experiments.elevationLadder):
// one closed path, so the glass's fill, its frost and its hairline rim are the same shape and the
// arrow is never a separate square stuck on the panel. The flat edge curves up into the notch and
// rounds over its tip with horizontal tangents at both ends, so the outline has no corner anywhere.

/** Which edge of the panel carries the notch: the one facing the anchor. */
export type NotchEdge = "top" | "right" | "bottom" | "left";

/** The notch's width along the edge and how far its tip stands out from it, in CSS px. */
export const NOTCH_WIDTH = 22;
export const NOTCH_HEIGHT = 9;

type Point = readonly [number, number];
type Edge = { start: Point; along: Point; out: Point; length: number };

const round = (value: number) => Math.round(value * 100) / 100;

/** The panel's four edges clockwise, each with its direction and outward normal. */
function edges(width: number, height: number): Record<NotchEdge, Edge> {
  return {
    top: { start: [0, 0], along: [1, 0], out: [0, -1], length: width },
    right: { start: [width, 0], along: [0, 1], out: [1, 0], length: height },
    bottom: { start: [width, height], along: [-1, 0], out: [0, 1], length: width },
    left: { start: [0, height], along: [0, -1], out: [-1, 0], length: height },
  };
}

const ORDER: readonly NotchEdge[] = ["top", "right", "bottom", "left"];

/**
 * Where the notch's tip sits along its edge, measured from the panel's left (top and bottom edges)
 * or top (left and right edges): `offset` kept on the straight part, clear of both corners. An edge
 * too short for the notch puts it at the middle.
 */
export function clampNotchOffset(length: number, radius: number, offset: number, notchWidth = NOTCH_WIDTH): number {
  const min = radius + notchWidth / 2;
  const max = length - radius - notchWidth / 2;
  if (max < min) return length / 2;
  return Math.min(max, Math.max(min, offset));
}

/**
 * The SVG path (also a CSS `path()`) of a `width` x `height` panel with corner `radius` and a notch on
 * `edge` whose tip is at `offset`. `pad` moves the whole outline right and down, for a layer that
 * starts `pad` outside the panel on every side so the notch fits in it.
 */
export function notchOutlinePath(
  width: number,
  height: number,
  radius: number,
  edge: NotchEdge,
  offset: number,
  notchWidth = NOTCH_WIDTH,
  notchHeight = NOTCH_HEIGHT,
  pad = 0,
): string {
  const r = Math.max(0, Math.min(radius, width / 2, height / 2));
  const all = edges(width, height);
  const point = (e: Edge, t: number, k: number) =>
    `${round(e.start[0] + e.along[0] * t + e.out[0] * k + pad)} ${round(e.start[1] + e.along[1] * t + e.out[1] * k + pad)}`;
  const top = all.top;
  const parts = [`M ${point(top, r, 0)}`];
  ORDER.forEach((name, index) => {
    const e = all[name];
    if (name === edge) {
      // The offset is in panel coordinates; the bottom and left edges run backwards along it.
      const tip = clampNotchOffset(e.length, r, offset, notchWidth);
      const along = name === "bottom" || name === "left" ? e.length - tip : tip;
      const a = along - notchWidth / 2;
      const b = along + notchWidth / 2;
      parts.push(
        `L ${point(e, a, 0)}`,
        `C ${point(e, a + notchWidth * 0.25, 0)} ${point(e, along - notchWidth * 0.18, notchHeight)} ${point(e, along, notchHeight)}`,
        `C ${point(e, along + notchWidth * 0.18, notchHeight)} ${point(e, b - notchWidth * 0.25, 0)} ${point(e, b, 0)}`,
      );
    }
    parts.push(`L ${point(e, e.length - r, 0)}`);
    const next = all[ORDER[(index + 1) % ORDER.length]!];
    if (r > 0) parts.push(`A ${round(r)} ${round(r)} 0 0 1 ${point(next, r, 0)}`);
  });
  parts.push("Z");
  return parts.join(" ");
}

/** The notched edge for the side of the anchor the popover opened on (Base UI's `data-side`). */
export function notchEdgeForSide(side: string | null, rtl = false): NotchEdge | undefined {
  switch (side) {
    case "bottom":
      return "top";
    case "top":
      return "bottom";
    case "right":
      return "left";
    case "left":
      return "right";
    case "inline-end":
      return rtl ? "right" : "left";
    case "inline-start":
      return rtl ? "left" : "right";
    default:
      return undefined;
  }
}
