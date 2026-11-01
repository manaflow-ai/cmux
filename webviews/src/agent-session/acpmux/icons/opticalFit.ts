import { ROW_VIEWBOX } from "./iconSize";
import type { IconLayer } from "./types";

/// A fitted row icon's ink, stroke included, spans this many units of the row's 19-unit crop on its
/// longer side, so a wide glyph (a Mac) and a tall one (a phone) read as one size in an icon column.
export const INK_BOX = 17;
/// The crop a row icon draws in (ROW_VIEWBOX's width).
const ROW_SPAN = 19;
const DEFAULT_STROKE = 1.5;

type Box = { x0: number; y0: number; x1: number; y1: number };

const NUMBER = /-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g;

/// The parameters in [0, 1] where one coordinate of a cubic has a turning point.
function cubicExtrema(p0: number, p1: number, p2: number, p3: number): number[] {
  const a = -p0 + 3 * p1 - 3 * p2 + p3;
  const b = 2 * (p0 - 2 * p1 + p2);
  const c = p1 - p0;
  const roots: number[] = [];
  if (Math.abs(a) < 1e-9) {
    if (Math.abs(b) > 1e-9) roots.push(-c / b);
  } else {
    const disc = b * b - 4 * a * c;
    if (disc >= 0) {
      const sq = Math.sqrt(disc);
      roots.push((-b + sq) / (2 * a), (-b - sq) / (2 * a));
    }
  }
  return roots.filter((t) => t > 0 && t < 1);
}

const cubicAt = (p0: number, p1: number, p2: number, p3: number, t: number) => {
  const u = 1 - t;
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
};

/// The exact geometric bounds of one path (the pack uses only absolute M, L, C and Z), with no stroke.
function pathBounds(d: string, box: Box) {
  const add = (x: number, y: number) => {
    box.x0 = Math.min(box.x0, x);
    box.y0 = Math.min(box.y0, y);
    box.x1 = Math.max(box.x1, x);
    box.y1 = Math.max(box.y1, y);
  };
  let x = 0;
  let y = 0;
  for (const [, command, args] of d.matchAll(/([MLCZ])([^MLCZ]*)/gi)) {
    const n = (args.match(NUMBER) ?? []).map(Number);
    const op = command.toUpperCase();
    if (op === "M" || op === "L") {
      for (let i = 0; i + 1 < n.length; i += 2) {
        x = n[i];
        y = n[i + 1];
        add(x, y);
      }
    } else if (op === "C") {
      for (let i = 0; i + 5 < n.length; i += 6) {
        const [x1, y1, x2, y2, x3, y3] = n.slice(i, i + 6);
        for (const t of cubicExtrema(x, x1, x2, x3)) add(cubicAt(x, x1, x2, x3, t), y);
        for (const t of cubicExtrema(y, y1, y2, y3)) add(x, cubicAt(y, y1, y2, y3, t));
        x = x3;
        y = y3;
        add(x, y);
      }
    }
  }
}

/// The drawn layers' geometric bounds (erasing layers excluded) and their widest stroke, or nothing
/// for an empty drawing.
export function inkBounds(layers: readonly IconLayer[]): (Box & { stroke: number }) | undefined {
  const box: Box = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
  let stroke = 0;
  for (const layer of layers) {
    if (layer.op !== "stroke" && layer.op !== "fill") continue;
    pathBounds(layer.d, box);
    if (layer.op === "stroke") stroke = Math.max(stroke, layer.w ?? DEFAULT_STROKE);
  }
  return Number.isFinite(box.x0) ? { ...box, stroke } : undefined;
}

const fits = new WeakMap<readonly IconLayer[], { viewBox: string; layers: IconLayer[] }>();

/// A row icon fitted to the icon column: its ink centred on the slot and scaled so its longer side
/// spans INK_BOX units of the row crop, with every stroke widened or narrowed by the inverse scale so
/// it draws at the pack's weight. Glyphs drawn to different extents (a short Mac, a phone taller than
/// the crop) then share one optical size, centre and stroke.
export function opticalRowFit(layers: IconLayer[]): { viewBox: string; layers: IconLayer[] } {
  const cached = fits.get(layers);
  if (cached) return cached;
  const ink = inkBounds(layers);
  let fit = { viewBox: ROW_VIEWBOX, layers };
  if (ink) {
    const longest = Math.max(ink.x1 - ink.x0, ink.y1 - ink.y0);
    const stroke = ink.stroke || 0;
    // Units of the drawing per unit of the row crop: the geometry spans INK_BOX less one stroke.
    const scale = longest > 0 ? longest / (INK_BOX - stroke) : 1;
    const span = ROW_SPAN * scale;
    const cx = (ink.x0 + ink.x1) / 2;
    const cy = (ink.y0 + ink.y1) / 2;
    const round = (v: number) => Math.round(v * 1000) / 1000;
    fit = {
      viewBox: [cx - span / 2, cy - span / 2, span, span].map(round).join(" "),
      layers: layers.map((layer) =>
        layer.op === "stroke" || layer.op === "clearStroke"
          ? { ...layer, w: round((layer.w ?? DEFAULT_STROKE) * scale) }
          : layer,
      ),
    };
  }
  fits.set(layers, fit);
  return fit;
}
