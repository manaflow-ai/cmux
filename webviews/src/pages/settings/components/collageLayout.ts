// Collage geometry for the editor (backgrounds plan phase 7): frames are fractions of a 16:10
// canvas from its top-left corner, as BackdropCollage stores them.
export type CollageLayer = {
  source: string;
  x: number;
  y: number;
  width: number;
  height: number;
  opacity: number;
  cornerRadius: number;
};
export type Collage = { name: string; fill: string; layers: CollageLayer[] };

export const MAX_LAYERS = 12;
const MIN_SIDE = 0.05;
/** Where edges snap: the canvas edges, its thirds and its middle. */
const LINES = [0, 1 / 3, 1 / 2, 2 / 3, 1];
const SNAP = 0.015;

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

/** `value` moved onto a snap line when it is within reach of one. */
export function snap(value: number): number {
  const line = LINES.find((line) => Math.abs(line - value) <= SNAP);
  return line ?? value;
}

/** `layer` moved by `dx`, `dy` (fractions), kept on the canvas, its left/top or right/bottom
 * edge snapped to the nearest line. */
export function moved(layer: CollageLayer, dx: number, dy: number): CollageLayer {
  const axis = (start: number, size: number, delta: number) => {
    const next = clamp(start + delta, 0, 1 - size);
    const lead = snap(next);
    if (lead !== next) return clamp(lead, 0, 1 - size);
    const trail = snap(next + size);
    return trail !== next + size ? clamp(trail - size, 0, 1 - size) : next;
  };
  return { ...layer, x: axis(layer.x, layer.width, dx), y: axis(layer.y, layer.height, dy) };
}

/** `layer` resized from its bottom-right corner by `dw`, `dh`, kept on the canvas and snapped. */
export function resized(layer: CollageLayer, dw: number, dh: number): CollageLayer {
  const width = clamp(snap(layer.x + layer.width + dw) - layer.x, MIN_SIDE, 1 - layer.x);
  const height = clamp(snap(layer.y + layer.height + dh) - layer.y, MIN_SIDE, 1 - layer.y);
  return { ...layer, width, height };
}

export type CollageLayoutName = "two" | "three" | "mosaic";

/** The frames of a starter layout, for as many pictures as it holds. */
export function layoutFrames(name: CollageLayoutName): Array<Pick<CollageLayer, "x" | "y" | "width" | "height">> {
  const gap = 0.02;
  switch (name) {
    case "two":
      return [
        { x: gap, y: gap, width: 0.5 - 1.5 * gap, height: 1 - 2 * gap },
        { x: 0.5 + gap / 2, y: gap, width: 0.5 - 1.5 * gap, height: 1 - 2 * gap },
      ];
    case "three":
      return [0, 1, 2].map((i) => ({
        x: gap + i * ((1 - gap) / 3),
        y: gap,
        width: (1 - gap) / 3 - gap,
        height: 1 - 2 * gap,
      }));
    case "mosaic":
      return [
        { x: gap, y: gap, width: 0.6 - 1.5 * gap, height: 1 - 2 * gap },
        { x: 0.6 + gap / 2, y: gap, width: 0.4 - 1.5 * gap, height: 0.5 - 1.5 * gap },
        { x: 0.6 + gap / 2, y: 0.5 + gap / 2, width: 0.4 - 1.5 * gap, height: 0.5 - 1.5 * gap },
      ];
  }
}

/** `collage` with the layout's frames given to its first pictures (the rest keep theirs). */
export function arranged(collage: Collage, name: CollageLayoutName): Collage {
  const frames = layoutFrames(name);
  return { ...collage, layers: collage.layers.map((layer, i) => (frames[i] ? { ...layer, ...frames[i] } : layer)) };
}

/** `layers` with the one at `index` moved `by` places toward the front (positive) or back. */
export function restacked(layers: CollageLayer[], index: number, by: number): CollageLayer[] {
  const target = clamp(index + by, 0, layers.length - 1);
  if (target === index) return layers;
  const next = [...layers];
  const [layer] = next.splice(index, 1);
  next.splice(target, 0, layer!);
  return next;
}

/** A new picture's frame: centered, a third of the canvas wide, offset for each one already there. */
export function placed(source: string, count: number): CollageLayer {
  const offset = (count % 5) * 0.04;
  return {
    source,
    x: 1 / 3 - 0.08 + offset,
    y: 1 / 6 + offset,
    width: 1 / 3,
    height: 1 / 2,
    opacity: 1,
    cornerRadius: 0,
  };
}
