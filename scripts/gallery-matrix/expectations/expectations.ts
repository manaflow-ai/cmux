// The visual expectations: one JSON file per surface under design/visual-expectations/<platform>/,
// naming the states to capture, how many pixels may move before a state counts as changed, and the
// "keep" regions that must never change without a justification in the PR body
// (design/visual-expectations/README.md has the contract).
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const PLATFORMS = ["web", "mac", "ios"] as const;
export type Platform = (typeof PLATFORMS)[number];
export const SCHEMES = ["light", "dark"] as const;
export type Scheme = (typeof SCHEMES)[number];

/** A region that must not change without say-so: a CSS selector (web, resolved at capture) or a box in CSS px / points. */
export type KeepRegion = { name: string; why: string; selector?: string; box?: [x: number, y: number, w: number, h: number] };

export type CaptureSpec = {
  /** The state's name: the file is <state>-<scheme>.png. */
  state: string;
  /** web: the gallery entry and variant (webviews/src/gallery/env.ts). */
  entry?: string;
  variant?: string;
  width?: number;
  height?: number;
  /** web: the element to crop to (default `[data-gallery-capture]`, then `#root`). */
  selector?: string;
  /** web: attributes set on <html> before the stage mounts, as a shipped page's main.tsx sets them
   *  (e.g. {"data-transient-material": ""}), so a state shows the page's opted-in look. */
  rootAttributes?: Record<string, string>;
  /** mac: a capture state file for `cmux-ci capture` (build-fleet/pr_capture/states or scripts/cmux-next/visual-gate/states). */
  stateFile?: string;
  /** ios: launch arguments for the gallery root (RecoveryGalleryRoot), e.g. ["-cmux-mobile-recovery-gallery", "states"]. */
  launch?: string[];
  keep?: KeepRegion[];
};

export type Tolerance = {
  /** Share of the image's pixels that may differ before the state counts as changed (0.001 = 0.1%). */
  ratio: number;
  /** pixelmatch's per-pixel colour threshold (0..1); 0.1 is the matrix default. */
  threshold: number;
};

export type Surface = {
  id: string;
  platform: Platform;
  title: string;
  /** The design spec this surface answers to, repo-relative. */
  spec?: string;
  schemes: Scheme[];
  tolerance: Tolerance;
  keep: KeepRegion[];
  captures: CaptureSpec[];
};

export const DEFAULT_TOLERANCE: Tolerance = { ratio: 0.0005, threshold: 0.1 };

/** `web/ui.menu`: how the PR body, the report and the file layout name a surface. */
export const surfaceRef = (s: Pick<Surface, "platform" | "id">) => `${s.platform}/${s.id}`;

const ID = /^[a-z0-9][a-z0-9.-]*$/;

/** Checks one parsed file; throws with the file and the field on the first problem. */
export function validateSurface(raw: unknown, file: string, platform: Platform): Surface {
  const fail = (why: string): never => {
    throw new Error(`${file}: ${why}`);
  };
  if (!raw || typeof raw !== "object") fail("not an object");
  const s = raw as Record<string, unknown>;
  if (typeof s.id !== "string" || !ID.test(s.id)) fail("id must be lower-case letters, digits, dots and dashes");
  if (s.platform !== undefined && s.platform !== platform) fail(`platform ${String(s.platform)} sits under ${platform}/`);
  if (typeof s.title !== "string" || !s.title) fail("title is required");
  const schemes = (s.schemes ?? [...SCHEMES]) as Scheme[];
  if (!Array.isArray(schemes) || !schemes.length || schemes.some((x) => !SCHEMES.includes(x))) fail("schemes must be light and/or dark");
  const tol = { ...DEFAULT_TOLERANCE, ...((s.tolerance as Partial<Tolerance>) ?? {}) };
  if (!(tol.ratio >= 0 && tol.ratio < 1) || !(tol.threshold >= 0 && tol.threshold <= 1)) fail("tolerance out of range");
  const keep = (k: unknown, where: string): KeepRegion[] => {
    if (k === undefined) return [];
    if (!Array.isArray(k)) return fail(`${where} must be a list`);
    return k.map((r, i) => {
      const region = r as KeepRegion;
      if (!region || typeof region.name !== "string" || typeof region.why !== "string" || !region.why)
        fail(`${where}[${i}] needs a name and a why`);
      if (!region.selector === !region.box) fail(`${where}[${i}] needs exactly one of selector or box`);
      if (region.box && (region.box.length !== 4 || region.box.some((n) => typeof n !== "number" || n < 0)))
        fail(`${where}[${i}].box must be [x, y, w, h]`);
      if (region.selector && platform !== "web") fail(`${where}[${i}]: selectors only resolve on web; use box`);
      return region;
    });
  };
  if (!Array.isArray(s.captures) || !s.captures.length) fail("captures must list at least one state");
  const states = new Set<string>();
  const captures = (s.captures as CaptureSpec[]).map((c, i) => {
    if (!c || typeof c.state !== "string" || !ID.test(c.state)) fail(`captures[${i}].state must be an id`);
    if (states.has(c.state)) fail(`captures[${i}].state ${c.state} repeats`);
    states.add(c.state);
    if (platform === "web" && (typeof c.entry !== "string" || typeof c.variant !== "string"))
      fail(`captures[${i}] needs entry and variant on web`);
    if (c.rootAttributes !== undefined && (platform !== "web" || typeof c.rootAttributes !== "object" || Object.values(c.rootAttributes).some((v) => typeof v !== "string")))
      fail(`captures[${i}].rootAttributes must map names to strings, on web only`);
    if (platform === "mac" && typeof c.stateFile !== "string") fail(`captures[${i}] needs stateFile on mac`);
    if (platform === "ios" && !Array.isArray(c.launch)) fail(`captures[${i}] needs launch on ios`);
    return { ...c, keep: keep(c.keep, `captures[${i}].keep`) };
  });
  return {
    id: s.id as string,
    platform,
    title: s.title as string,
    spec: typeof s.spec === "string" ? s.spec : undefined,
    schemes,
    tolerance: tol,
    keep: keep(s.keep, "keep"),
    captures,
  };
}

/** Every surface under root (design/visual-expectations), sorted by ref; a repeated id is an error. */
export function loadSurfaces(root: string, platforms: readonly Platform[] = PLATFORMS): Surface[] {
  const surfaces: Surface[] = [];
  for (const platform of platforms) {
    const dir = join(root, platform);
    if (!existsSync(dir)) continue;
    for (const name of readdirSync(dir).filter((n) => n.endsWith(".json")).sort()) {
      const file = join(dir, name);
      const surface = validateSurface(JSON.parse(readFileSync(file, "utf8")), file, platform);
      if (`${surface.id}.json` !== name) throw new Error(`${file}: file name must be ${surface.id}.json`);
      surfaces.push(surface);
    }
  }
  return surfaces.sort((a, b) => surfaceRef(a).localeCompare(surfaceRef(b)));
}

/** The keep regions that apply to one state: the surface's and the state's own. */
export const keepFor = (s: Surface, c: CaptureSpec): KeepRegion[] => [...s.keep, ...(c.keep ?? [])];

/** Where a state's picture lives under a captures or baselines root. */
export const shotPath = (root: string, s: Pick<Surface, "platform" | "id">, state: string, scheme: Scheme) =>
  join(root, s.platform, s.id, `${state}-${scheme}.png`);
