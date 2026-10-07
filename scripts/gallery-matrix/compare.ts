// The per-PR gallery diff: pairs the matrix rendered at a PR's merge-base with the same matrix at its
// head, finds the changed regions of each state, and sorts states into changed, new, removed,
// unchanged, nondeterministic (the head differs from a second render of itself: a clock or fixture
// leak, never shown as a PR change) and broken (the head stage failed to mount).
import { PNG } from "pngjs";
import pixelmatch from "pixelmatch";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type Shot = {
  id: string;
  engine: string;
  screenshot: string;
  params?: Record<string, unknown>;
  ready?: string | null;
};
export type Status = "changed" | "new" | "removed" | "nondeterministic" | "broken" | "unchanged";
export type Box = { x: number; y: number; w: number; h: number };
export type Outcome = {
  /** The screenshot name, the same in every run: `<case id>-<engine>.png`. */
  key: string;
  id: string;
  entry: string;
  variant: string;
  theme: string;
  engine: string;
  status: Status;
  /** Images under the diff folder: base/<key>, head/<key>, thumbs/<key>. */
  base?: string;
  head?: string;
  thumb?: string;
  width: number;
  height: number;
  pixels: number;
  /** Changed pixels over the larger image's pixels, 0..1. */
  ratio: number;
  boxes: Box[];
};

/** Statuses in the order the page and the comment list them. */
export const STATUS_ORDER: Status[] = ["changed", "new", "removed", "broken", "nondeterministic", "unchanged"];

const CELL = 8;
const MERGE_CELLS = 3;
const MAX_BOXES = 12;
const THUMB_PAD = 24;
const THUMB_MAX_WIDTH = 960;

/** Both images on one canvas the size of the larger; the area only one of them has is transparent. */
function padTo(png: PNG, width: number, height: number): Buffer {
  if (png.width === width && png.height === height) return png.data;
  const out = Buffer.alloc(width * height * 4);
  for (let y = 0; y < png.height; y++) png.data.copy(out, y * width * 4, y * png.width * 4, (y + 1) * png.width * 4);
  return out;
}

/**
 * One flag per pixel: 1 where the two images differ. Anti-aliasing counts: both sides render on the
 * same machine, so a changed edge is a real change, and noise is the flake guard's to catch.
 */
export function diffMask(a: PNG, b: PNG): { mask: Uint8Array; width: number; height: number; pixels: number } {
  const width = Math.max(a.width, b.width);
  const height = Math.max(a.height, b.height);
  const output = Buffer.alloc(width * height * 4);
  pixelmatch(padTo(a, width, height), padTo(b, width, height), output, width, height, {
    threshold: 0.1,
    includeAA: true,
    diffMask: true,
    diffColor: [255, 0, 0],
  });
  const mask = new Uint8Array(width * height);
  let pixels = 0;
  for (let i = 0; i < mask.length; i++) {
    const o = i * 4;
    if (output[o + 3]! > 0) {
      mask[i] = 1;
      pixels++;
    }
  }
  return { mask, width, height, pixels };
}

/**
 * The changed regions: the mask in CELL-pixel cells, cells closer than MERGE_CELLS joined, one box
 * per group. More than MAX_BOXES groups become their own bounding box, so the overlay stays legible.
 */
export function changedBoxes(mask: Uint8Array, width: number, height: number): Box[] {
  const cols = Math.ceil(width / CELL);
  const rows = Math.ceil(height / CELL);
  const dirty = new Uint8Array(cols * rows);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) if (mask[y * width + x]) dirty[Math.floor(y / CELL) * cols + Math.floor(x / CELL)] = 1;
  const group = new Int32Array(cols * rows).fill(-1);
  const boxes: Box[] = [];
  for (let start = 0; start < dirty.length; start++) {
    if (!dirty[start] || group[start] !== -1) continue;
    let [x0, y0, x1, y1] = [cols, rows, -1, -1];
    const stack = [start];
    group[start] = boxes.length;
    while (stack.length) {
      const cell = stack.pop()!;
      const cx = cell % cols;
      const cy = Math.floor(cell / cols);
      [x0, y0, x1, y1] = [Math.min(x0, cx), Math.min(y0, cy), Math.max(x1, cx), Math.max(y1, cy)];
      for (let dy = -MERGE_CELLS; dy <= MERGE_CELLS; dy++)
        for (let dx = -MERGE_CELLS; dx <= MERGE_CELLS; dx++) {
          const nx = cx + dx;
          const ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
          const next = ny * cols + nx;
          if (dirty[next] && group[next] === -1) {
            group[next] = boxes.length;
            stack.push(next);
          }
        }
    }
    const x = x0 * CELL;
    const y = y0 * CELL;
    boxes.push({ x, y, w: Math.min((x1 + 1) * CELL, width) - x, h: Math.min((y1 + 1) * CELL, height) - y });
  }
  if (boxes.length <= MAX_BOXES) return boxes.sort((a, b) => a.y - b.y || a.x - b.x);
  return [union(boxes)];
}

function union(boxes: Box[]): Box {
  const x = Math.min(...boxes.map((b) => b.x));
  const y = Math.min(...boxes.map((b) => b.y));
  return {
    x,
    y,
    w: Math.max(...boxes.map((b) => b.x + b.w)) - x,
    h: Math.max(...boxes.map((b) => b.y + b.h)) - y,
  };
}

function crop(png: PNG, box: Box): PNG {
  const out = new PNG({ width: box.w, height: box.h });
  for (let y = 0; y < box.h; y++) {
    const sy = box.y + y;
    if (sy >= png.height) break;
    const w = Math.max(0, Math.min(box.w, png.width - box.x));
    png.data.copy(out.data, y * box.w * 4, (sy * png.width + box.x) * 4, (sy * png.width + box.x + w) * 4);
  }
  return out;
}

/** Halves an image by averaging 2x2 pixels (the matrix renders at device scale 2). */
function half(png: PNG): PNG {
  const width = Math.max(1, Math.floor(png.width / 2));
  const height = Math.max(1, Math.floor(png.height / 2));
  const out = new PNG({ width, height });
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++)
      for (let c = 0; c < 4; c++) {
        let sum = 0;
        for (const [dx, dy] of [[0, 0], [1, 0], [0, 1], [1, 1]] as const)
          sum += png.data[((y * 2 + dy) * png.width + (x * 2 + dx)) * 4 + c] ?? 0;
        out.data[(y * width + x) * 4 + c] = Math.round(sum / 4);
      }
  return out;
}

/**
 * The changed region of both sides next to each other, before on the left: the region around every
 * box, padded, in the larger image's coordinates, halved until it fits the comment's width.
 */
export function beforeAfterThumb(base: PNG, head: PNG, boxes: Box[]): PNG {
  const width = Math.max(base.width, head.width);
  const height = Math.max(base.height, head.height);
  const all = union(boxes);
  const x = Math.max(0, all.x - THUMB_PAD);
  const y = Math.max(0, all.y - THUMB_PAD);
  const region = { x, y, w: Math.min(width, all.x + all.w + THUMB_PAD) - x, h: Math.min(height, all.y + all.h + THUMB_PAD) - y };
  const gap = 8;
  let out = new PNG({ width: region.w * 2 + gap, height: region.h });
  out.data.fill(0);
  for (const [side, png] of [[0, base], [1, head]] as const) {
    const part = crop(png, region);
    for (let row = 0; row < region.h; row++)
      part.data.copy(out.data, (row * out.width + side * (region.w + gap)) * 4, row * region.w * 4, (row + 1) * region.w * 4);
  }
  while (out.width > THUMB_MAX_WIDTH) out = half(out);
  return out;
}

const readPng = (file: string) => PNG.sync.read(readFileSync(file));

function readShots(dir: string): Map<string, Shot> {
  const file = join(dir, "results.json");
  if (!existsSync(file)) return new Map();
  const shots = JSON.parse(readFileSync(file, "utf8")) as Shot[];
  return new Map(shots.map((shot) => [shot.screenshot, shot]));
}

export type CompareRuns = {
  /** The matrix at the merge-base, at the head, and the head rendered a second time. */
  baseDir: string;
  headDir: string;
  repeatDir?: string;
  /** Case ids each side's gallery has (its manifest); an id only the head has is new. */
  baseIds: Set<string>;
  headIds: Set<string>;
  outDir: string;
};

/** Compares the runs and writes base/, head/ and thumbs/ under outDir for the changed states. */
export function compareRuns(args: CompareRuns): Outcome[] {
  const base = readShots(args.baseDir);
  const head = readShots(args.headDir);
  const repeat = args.repeatDir ? readShots(args.repeatDir) : undefined;
  for (const dir of ["base", "head", "thumbs"]) mkdirSync(join(args.outDir, dir), { recursive: true });
  const keep = (side: "base" | "head", dir: string, key: string) => {
    copyFileSync(join(dir, key), join(args.outDir, side, key));
    return `${side}/${key}`;
  };
  const outcomes: Outcome[] = [];
  for (const key of [...new Set([...base.keys(), ...head.keys()])].sort()) {
    const shot = (head.get(key) ?? base.get(key))!;
    const params = shot.params ?? {};
    const inBase = args.baseIds.has(shot.id) && base.get(key)?.ready === "1";
    const inHead = args.headIds.has(shot.id);
    const outcome: Outcome = {
      key,
      id: shot.id,
      entry: String(params.entry ?? shot.id),
      variant: String(params.variant ?? ""),
      theme: String(params.theme ?? ""),
      engine: shot.engine,
      status: "unchanged",
      width: 0,
      height: 0,
      pixels: 0,
      ratio: 0,
      boxes: [],
    };
    outcomes.push(outcome);
    if (inHead && head.get(key)?.ready !== "1") {
      outcome.status = "broken";
      if (head.has(key) && existsSync(join(args.headDir, key))) outcome.head = keep("head", args.headDir, key);
      continue;
    }
    if (!inHead) {
      outcome.status = "removed";
      if (inBase) outcome.base = keep("base", args.baseDir, key);
      continue;
    }
    const headPng = readPng(join(args.headDir, key));
    [outcome.width, outcome.height] = [headPng.width, headPng.height];
    const again = repeat?.get(key);
    if (repeat && again?.ready === "1") {
      const self = diffMask(headPng, readPng(join(args.repeatDir!, key)));
      if (self.pixels > 0) {
        outcome.status = "nondeterministic";
        outcome.pixels = self.pixels;
        outcome.ratio = self.pixels / (self.width * self.height);
        outcome.boxes = changedBoxes(self.mask, self.width, self.height);
        outcome.head = keep("head", args.headDir, key);
        continue;
      }
    }
    if (!inBase) {
      outcome.status = "new";
      outcome.head = keep("head", args.headDir, key);
      continue;
    }
    const basePng = readPng(join(args.baseDir, key));
    const diff = diffMask(basePng, headPng);
    if (diff.pixels === 0) continue;
    outcome.status = "changed";
    [outcome.width, outcome.height] = [diff.width, diff.height];
    outcome.pixels = diff.pixels;
    outcome.ratio = diff.pixels / (diff.width * diff.height);
    outcome.boxes = changedBoxes(diff.mask, diff.width, diff.height);
    outcome.base = keep("base", args.baseDir, key);
    outcome.head = keep("head", args.headDir, key);
    outcome.thumb = `thumbs/${key}`;
    writeFileSync(join(args.outDir, outcome.thumb), PNG.sync.write(beforeAfterThumb(basePng, headPng, outcome.boxes)));
  }
  return outcomes.sort(
    (a, b) => STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status) || b.ratio - a.ratio || a.key.localeCompare(b.key),
  );
}
