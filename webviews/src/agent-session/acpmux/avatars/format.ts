// Animated avatars (`cmux-avatar/1`): a sprite sheet of same-size frames, one row per agent state,
// and a small JSON manifest naming each state's row and frame count (after Codex's pets, whose
// sheets keep one animation per row and draw running-left/running-right as their own rows). The
// Chief pet, Chief avatars and agent avatars share it; a person's own upload is checked here too.
// Pure: no DOM, so the native side and the upload path read the same rules.

export const AVATAR_FORMAT = "cmux-avatar/1";
export const AVATAR_STATES = ["idle", "working", "thinking", "waiting", "done", "error"] as const;
export type AvatarState = (typeof AVATAR_STATES)[number];
export type AvatarFacing = "left" | "right";

export type AvatarStateSpec = {
  row: number;
  frames: number;
  fps?: number;
  loop?: boolean;
  rowLeft?: number;
  rowRight?: number;
};

export type AvatarManifest = {
  format: typeof AVATAR_FORMAT;
  id: string;
  name: string;
  sheet: string;
  frame: { width: number; height: number };
  fps: number;
  pixelArt: boolean;
  faces: AvatarFacing;
  states: Partial<Record<AvatarState, AvatarStateSpec>> & { idle: AvatarStateSpec };
};

/** What draws one state: its row, frames, rate, whether it loops, and whether the row is mirrored. */
export type AvatarTrack = { row: number; frames: number; fps: number; loop: boolean; mirrored: boolean };

const MAX_FRAMES = 16;
const MAX_ROWS = 16;
/** The largest sheet the manifest may need, in px on each side. */
const MAX_SHEET = 2048;
/** Where a state with no row of its own borrows one. */
const FALLBACK: Record<AvatarState, AvatarState | null> = {
  idle: null,
  working: "idle",
  thinking: "working",
  waiting: "idle",
  done: "idle",
  error: "idle",
};

const int = (value: unknown, min: number, max: number): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= min && value <= max ? value : null;

const rate = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) && value >= 1 && value <= 30 ? value : null;

function stateSpec(value: unknown, name: string): AvatarStateSpec | string {
  if (!value || typeof value !== "object") return `states.${name} must be an object`;
  const raw = value as Record<string, unknown>;
  const row = int(raw.row, 0, MAX_ROWS - 1);
  const frames = int(raw.frames, 1, MAX_FRAMES);
  if (row === null) return `states.${name}.row must be a row from 0 to ${MAX_ROWS - 1}`;
  if (frames === null) return `states.${name}.frames must be 1 to ${MAX_FRAMES}`;
  const spec: AvatarStateSpec = { row, frames };
  if (raw.fps !== undefined) {
    const fps = rate(raw.fps);
    if (fps === null) return `states.${name}.fps must be 1 to 30`;
    spec.fps = fps;
  }
  if (raw.loop !== undefined) {
    if (typeof raw.loop !== "boolean") return `states.${name}.loop must be true or false`;
    spec.loop = raw.loop;
  }
  for (const key of ["rowLeft", "rowRight"] as const) {
    if (raw[key] === undefined) continue;
    const other = int(raw[key], 0, MAX_ROWS - 1);
    if (other === null) return `states.${name}.${key} must be a row from 0 to ${MAX_ROWS - 1}`;
    spec[key] = other;
  }
  return spec;
}

/** The manifest, or why it is refused (one reason, for the upload's message). Unknown fields and states are ignored. */
export function parseAvatarManifest(value: unknown): { manifest: AvatarManifest } | { error: string } {
  if (!value || typeof value !== "object") return { error: "avatar.json must be an object" };
  const raw = value as Record<string, unknown>;
  if (raw.format !== AVATAR_FORMAT) return { error: `format must be "${AVATAR_FORMAT}"` };
  if (typeof raw.id !== "string" || !/^[a-z0-9-]{1,32}$/.test(raw.id))
    return { error: "id must be 1 to 32 of a-z, 0-9 and -" };
  if (typeof raw.name !== "string" || raw.name.trim() === "" || raw.name.length > 24)
    return { error: "name must be 1 to 24 characters" };
  if (typeof raw.sheet !== "string" || !/^[^/\\]+\.(png|webp)$/i.test(raw.sheet))
    return { error: "sheet must be a .png or .webp file next to avatar.json" };
  const frame = raw.frame as Record<string, unknown> | undefined;
  const width = int(frame?.width, 8, 256);
  const height = int(frame?.height, 8, 256);
  if (width === null || height === null) return { error: "frame.width and frame.height must be 8 to 256" };
  const fps = raw.fps === undefined ? 8 : rate(raw.fps);
  if (fps === null) return { error: "fps must be 1 to 30" };
  if (raw.faces !== undefined && raw.faces !== "left" && raw.faces !== "right")
    return { error: 'faces must be "left" or "right"' };
  if (raw.pixelArt !== undefined && typeof raw.pixelArt !== "boolean")
    return { error: "pixelArt must be true or false" };
  const rawStates = raw.states as Record<string, unknown> | undefined;
  if (!rawStates || typeof rawStates !== "object") return { error: "states must be an object" };
  const states: Partial<Record<AvatarState, AvatarStateSpec>> = {};
  for (const name of AVATAR_STATES) {
    if (rawStates[name] === undefined) continue;
    const spec = stateSpec(rawStates[name], name);
    if (typeof spec === "string") return { error: spec };
    states[name] = spec;
  }
  if (!states.idle) return { error: "states.idle is required" };
  const manifest: AvatarManifest = {
    format: AVATAR_FORMAT,
    id: raw.id,
    name: raw.name.trim(),
    sheet: raw.sheet,
    frame: { width, height },
    fps,
    pixelArt: raw.pixelArt === true,
    faces: raw.faces === "left" ? "left" : "right",
    states: { ...states, idle: states.idle },
  };
  const need = sheetSize(manifest);
  if (need.width > MAX_SHEET || need.height > MAX_SHEET)
    return { error: `the sheet these frames need (${need.width} x ${need.height} px) is over ${MAX_SHEET} px` };
  return { manifest };
}

/** The sheet's size in px that the manifest needs: the longest row's frames by the highest row used.
 * A sheet may be larger (padded); a renderer that cuts cells by background must use its real size. */
export function sheetSize(manifest: AvatarManifest): { width: number; height: number } {
  const specs = Object.values(manifest.states);
  const rows = specs.flatMap((spec) => [spec.row, spec.rowLeft ?? 0, spec.rowRight ?? 0]);
  return {
    width: Math.max(...specs.map((spec) => spec.frames)) * manifest.frame.width,
    height: (Math.max(...rows) + 1) * manifest.frame.height,
  };
}

/** How `state` draws facing `facing`: a missing state borrows its fallback's row, and the facing the
 * frames are not drawn in uses its own row (`rowLeft`/`rowRight`) when the manifest gives one, else
 * the same row mirrored. The facing the frames are drawn in always uses `row`. */
export function avatarTrack(manifest: AvatarManifest, state: AvatarState, facing: AvatarFacing): AvatarTrack {
  let name: AvatarState = state;
  while (!manifest.states[name]) name = FALLBACK[name] ?? "idle";
  const spec = manifest.states[name] ?? manifest.states.idle;
  const turned = facing !== manifest.faces;
  const own = !turned ? undefined : facing === "left" ? spec.rowLeft : spec.rowRight;
  return {
    row: own ?? spec.row,
    frames: spec.frames,
    fps: spec.fps ?? manifest.fps,
    loop: spec.loop ?? true,
    mirrored: turned && own === undefined,
  };
}
