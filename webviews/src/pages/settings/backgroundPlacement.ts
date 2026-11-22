// Where one background picture lies in its window (`appearance.backgroundPlacement`, Leo
// 2026-11-22: "we also want people to be able to reposition the images easily"). The math is Rust's
// (cmux-config `backdrop_placement`, the spec and its tests); this mirrors it for the Settings
// preview, which redraws on every pointer move. backgroundPlacement.test.ts checks it against the
// table the Rust tests write (cmux-tui/crates/cmux-config/tests/fixtures/backdrop-placement-cases.json).
// Rects use a top-left origin, y growing down.

export const PLACEMENT_KEY = "appearance.backgroundPlacement";

export type PlacementMode = "fill" | "fit" | "center" | "stretch";
export const PLACEMENT_MODES: readonly PlacementMode[] = ["fill", "fit", "center", "stretch"];

export interface Placement {
  mode: PlacementMode;
  /** 0 (left) to 1 (right). */
  x: number;
  /** 0 (top) to 1 (bottom). */
  y: number;
  /** 1 to 4. */
  zoom: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const ZOOM_MIN = 1;
export const ZOOM_MAX = 4;

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

/** A placement with the anchor clamped to 0...1 and the zoom to 1...4 (NaN is the default). */
export function placement(mode: PlacementMode = "fill", x = 0.5, y = 0.5, zoom = 1): Placement {
  return {
    mode,
    x: Number.isNaN(x) ? 0.5 : clamp(x, 0, 1),
    y: Number.isNaN(y) ? 0.5 : clamp(y, 0, 1),
    zoom: Number.isNaN(zoom) ? 1 : clamp(zoom, ZOOM_MIN, ZOOM_MAX),
  };
}

/** Unset: the picture fills the view, centered. */
export const CENTERED_FILL: Placement = placement();

export function isCenteredFill(value: Placement): boolean {
  return value.mode === "fill" && value.x === 0.5 && value.y === 0.5 && value.zoom === 1;
}

/** Reads one placement text (`fill`, `fit 0.25 0.5`, `fill 0.3 0.7 2`); null when it does not read. */
export function parsePlacement(text: unknown): Placement | null {
  if (typeof text !== "string") return null;
  const parts = text.split(/[ \t\n]+/).filter(Boolean);
  const mode = parts[0] as PlacementMode | undefined;
  if (!mode || !PLACEMENT_MODES.includes(mode)) return null;
  const number = (part: string) => (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(part) ? Number(part) : null);
  const unit = (part: string) => {
    const value = number(part);
    return value !== null && value >= 0 && value <= 1 ? value : null;
  };
  if (parts.length === 1) return placement(mode);
  if (parts.length !== 3 && parts.length !== 4) return null;
  const x = unit(parts[1]!);
  const y = unit(parts[2]!);
  if (x === null || y === null) return null;
  if (parts.length === 3) return placement(mode, x, y);
  const zoom = number(parts[3]!);
  if (zoom === null || zoom < ZOOM_MIN || zoom > ZOOM_MAX) return null;
  return placement(mode, x, y, zoom);
}

/** The shortest text that reads back the same. */
export function placementText(value: Placement): string {
  const number = (n: number) => {
    let text = n.toFixed(3);
    text = text.replace(/0+$/, "").replace(/\.$/, "");
    return text === "-0" ? "0" : text;
  };
  let out: string = value.mode;
  if (value.x !== 0.5 || value.y !== 0.5 || value.zoom !== 1) out += ` ${number(value.x)} ${number(value.y)}`;
  if (value.zoom !== 1) out += ` ${number(value.zoom)}`;
  return out;
}

/** Where the whole picture is drawn in a `view`-sized view; null when either has no area. */
export function placementRect(value: Placement, image: Size, view: Size): Rect | null {
  const positive = (n: number) => Number.isFinite(n) && n > 0;
  if (![image.width, image.height, view.width, view.height].every(positive)) return null;
  let width: number;
  let height: number;
  if (value.mode === "fill" || value.mode === "fit") {
    const sx = view.width / image.width;
    const sy = view.height / image.height;
    const scale = value.mode === "fill" ? Math.max(sx, sy) : Math.min(sx, sy);
    width = image.width * scale;
    height = image.height * scale;
  } else if (value.mode === "center") {
    ({ width, height } = image);
  } else {
    ({ width, height } = view);
  }
  width *= value.zoom;
  height *= value.zoom;
  return { x: (view.width - width) * value.x, y: (view.height - height) * value.y, width, height };
}

/** The part of the view the picture covers and the part of the picture drawn there (unit); null when it misses. */
export function placementVisible(value: Placement, image: Size, view: Size): { frame: Rect; contents: Rect } | null {
  const drawn = placementRect(value, image, view);
  if (!drawn) return null;
  const left = Math.max(drawn.x, 0);
  const top = Math.max(drawn.y, 0);
  const right = Math.min(drawn.x + drawn.width, view.width);
  const bottom = Math.min(drawn.y + drawn.height, view.height);
  if (right <= left || bottom <= top) return null;
  const frame = { x: left, y: top, width: right - left, height: bottom - top };
  const contents = {
    x: (frame.x - drawn.x) / drawn.width,
    y: (frame.y - drawn.y) / drawn.height,
    width: frame.width / drawn.width,
    height: frame.height / drawn.height,
  };
  return { frame, contents };
}

/** The placement after the picture is dragged `dx`, `dy` (right and down positive): it follows the pointer. */
export function placementDragged(value: Placement, image: Size, view: Size, dx: number, dy: number): Placement {
  const drawn = placementRect(value, image, view);
  if (!drawn) return value;
  const step = (anchor: number, delta: number, room: number) =>
    Math.abs(room) < 1e-9 ? anchor : clamp(anchor + delta / room, 0, 1);
  return placement(
    value.mode,
    step(value.x, dx, view.width - drawn.width),
    step(value.y, dy, view.height - drawn.height),
    value.zoom,
  );
}

const NO_PICTURE = ["none", "daily", "appearance", "schedule"];

/** The id `appearance.backgroundPlacement` keys a shown picture by (Rust `placement_key`): a dynamic
 * wallpaper's moment (`system:PATH|frame:N|dark`) keys its file, so every frame shares one place;
 * a Light & Dark pair, a mode, a folder shuffle or no picture keys nothing (null). */
export function placementKey(pictureID: string): string | null {
  const id = pictureID.trim();
  if (id === "" || NO_PICTURE.includes(id) || id.startsWith("folder:") || id.startsWith("appearance:")) return null;
  if (id.startsWith("system:")) {
    const cut = id.lastIndexOf("|frame:");
    if (cut > 0) {
      const moment = id.slice(cut + "|frame:".length);
      const frame = moment.endsWith("|light")
        ? moment.slice(0, -6)
        : moment.endsWith("|dark")
          ? moment.slice(0, -5)
          : null;
      if (frame !== null && /^[0-9]+$/.test(frame)) return id.slice(0, cut);
    }
  }
  return id;
}

/** The setting's map, read: entries that do not read are left out. */
export function readPlacements(value: unknown): Record<string, Placement> {
  const out: Record<string, Placement> = {};
  if (typeof value !== "object" || value === null || Array.isArray(value)) return out;
  for (const [id, text] of Object.entries(value)) {
    const read = id.trim() ? parsePlacement(text) : null;
    if (read) out[id] = read;
  }
  return out;
}

/** The setting's next value with picture `id` at `next`: a centered fill drops its entry; null when none is left. */
export function placementsValue(current: unknown, id: string, next: Placement): Record<string, string> | null {
  const out: Record<string, string> = {};
  for (const [key, read] of Object.entries(readPlacements(current))) out[key] = placementText(read);
  if (isCenteredFill(next)) delete out[id];
  else out[id] = placementText(next);
  return Object.keys(out).length > 0 ? out : null;
}

/** Whether a value is a map of picture ids to placement texts (the setting's validation). */
export function isPlacementMap(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.entries(value).every(([id, text]) => id.trim() !== "" && parsePlacement(text) !== null)
  );
}
