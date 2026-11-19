// The glass engine's optics, in plain numbers (design/glass.md, "Glass engine"). The shader in
// shaders.ts computes the same functions per pixel; tests run these to pin the look without WebGL.
//
// The model, taken from the open-source Liquid Glass implementations the desktop helper swept: a
// glass slab whose rim is a convex squircle bevel. A ray straight down through the bevel refracts by
// Snell's law and lands inward of where it entered, so the backdrop near the rim is pulled in from
// further inside; the flat center passes it straight. Frost, a per-channel split, a tint, a
// saturation lift and a light catching the rim's slope go on top.

/** Every look parameter of one glass layer. Lengths are CSS px. */
export type GlassLook = {
  /** Corner radius; clamped to half the short side. */
  radius: number;
  /** Corner shape: 2 is a circular arc, larger is a squircle (Apple's continuous corners ~ 3). */
  corner: number;
  /** How far in from the edge the bevel reaches; the center inside it is flat. */
  bevel: number;
  /** How tall the slab is: with `ior`, how far the bevel bends the backdrop. */
  thickness: number;
  /** Index of refraction, 1 (no bend) to 2. */
  ior: number;
  /** Frost: the backdrop's blur under the glass, as a gaussian sigma. */
  frost: number;
  /** Saturation of what shows through: 1 keeps it, Apple's glass lifts it a little. */
  saturation: number;
  /** Per-channel split of the bend, 0 (none) to 1. Costs two more frost taps per rim pixel. */
  dispersion: number;
  /** The light the rim catches, 0 to 1. */
  specular: number;
  /** Where the light comes from, radians; 0 is from the right, -PI/2 from above. */
  lightAngle: number;
  /** A color over what shows through: [r, g, b, a], 0 to 1, not premultiplied. */
  tint: readonly [number, number, number, number];
  /** A soft shadow outside the glass, 0 to 1. */
  shadow: number;
  opacity: number;
};

export const DEFAULT_LOOK: GlassLook = {
  radius: 22,
  corner: 2.6,
  bevel: 18,
  thickness: 22,
  ior: 1.5,
  frost: 6,
  saturation: 1.4,
  dispersion: 0,
  specular: 0.55,
  lightAngle: -2.2,
  tint: [1, 1, 1, 0.06],
  shadow: 0.3,
  opacity: 1,
};

/** Named looks the gallery and the taste lanes start from. */
export const GLASS_PRESETS = {
  /** The default: a clear slab with a modest bevel and frost. */
  regular: DEFAULT_LOOK,
  /** Clear: almost no frost, for glass over art. */
  clear: { ...DEFAULT_LOOK, frost: 1, saturation: 1.2, tint: [1, 1, 1, 0.02] },
  /** Thick: a deep bevel and a strong bend, for a single hero control. */
  thick: { ...DEFAULT_LOOK, bevel: 28, thickness: 40, specular: 0.8 },
  /** Prism: the thick slab with a per-channel split at the rim. */
  prism: { ...DEFAULT_LOOK, bevel: 28, thickness: 40, dispersion: 0.6, specular: 0.8 },
  /** Frosted: a menu's density, the bend still at the rim. */
  frosted: { ...DEFAULT_LOOK, frost: 16, tint: [0.12, 0.12, 0.14, 0.35], saturation: 1.6 },
} satisfies Record<string, GlassLook>;

export type GlassPreset = keyof typeof GLASS_PRESETS;

/** The bevel's height at `t` (0 on the edge, 1 where the flat center starts): a convex squircle,
 * (1 - (1 - t)^4)^(1/4). Steep at the edge, flat inside, so the bend fades with no visible seam. */
export function bevelHeight(t: number): number {
  const s = Math.min(Math.max(t, 0), 1);
  return Math.pow(1 - Math.pow(1 - s, 4), 0.25);
}

/** d height / d t, finite at the edge (the true slope is infinite at t = 0). */
export function bevelSlope(t: number): number {
  const s = Math.min(Math.max(t, 0.002), 1);
  const u = 1 - s;
  return Math.pow(1 - u * u * u * u, -0.75) * u * u * u;
}

/** How far inward a ray entering the bevel at `t` lands, CSS px: Snell's law at the bevel's surface
 * (a vertical ray through a surface tilted by the slope), carried down to the slab's floor. */
export function bendAt(t: number, bevel: number, thickness: number, ior: number): number {
  if (bevel <= 0 || thickness <= 0 || ior <= 1 || t >= 1) return 0;
  const slope = (bevelSlope(t) * thickness) / bevel;
  // The surface normal (outward tilt `slope`, up 1), normalized.
  const len = Math.hypot(slope, 1);
  const nx = slope / len;
  const nz = 1 / len;
  const eta = 1 / ior;
  // refract(I = (0, -1), N = (nx, nz), eta), as GLSL defines it.
  const cosI = nz;
  const k = 1 - eta * eta * (1 - cosI * cosI);
  if (k < 0) return 0;
  const a = eta * cosI - Math.sqrt(k);
  const rx = a * nx;
  const rz = -eta + a * nz;
  const depth = thickness * bevelHeight(t);
  // The ray goes inward (rx < 0); return the inward distance as a positive number.
  return (-rx / Math.max(-rz, 1e-3)) * depth;
}

/** Signed distance to a rounded rect whose corners are superellipses of exponent `corner`,
 * centered at the origin with half sizes (hw, hh): negative inside. Exact for corner 2. */
export function roundedRectDistance(
  px: number,
  py: number,
  hw: number,
  hh: number,
  radius: number,
  corner: number,
): number {
  const r = Math.min(radius, hw, hh);
  const qx = Math.abs(px) - (hw - r);
  const qy = Math.abs(py) - (hh - r);
  if (qx > 0 && qy > 0) {
    const n = Math.max(corner, 1);
    return Math.pow(Math.pow(qx, n) + Math.pow(qy, n), 1 / n) - r;
  }
  return Math.max(qx, qy) - r;
}

/** Fills a look from a partial, clamping every field to what the shader takes. */
export function resolveLook(partial: Partial<GlassLook> | undefined, base: GlassLook = DEFAULT_LOOK): GlassLook {
  const look = { ...base, ...partial };
  const clamp = (value: number, lo: number, hi: number, fallback: number) =>
    Number.isFinite(value) ? Math.min(Math.max(value, lo), hi) : fallback;
  const tint = look.tint.length === 4 ? look.tint : base.tint;
  return {
    radius: clamp(look.radius, 0, 4096, base.radius),
    corner: clamp(look.corner, 2, 6, base.corner),
    bevel: clamp(look.bevel, 0, 256, base.bevel),
    thickness: clamp(look.thickness, 0, 256, base.thickness),
    ior: clamp(look.ior, 1, 2, base.ior),
    frost: clamp(look.frost, 0, 64, base.frost),
    saturation: clamp(look.saturation, 0, 3, base.saturation),
    dispersion: clamp(look.dispersion, 0, 1, base.dispersion),
    specular: clamp(look.specular, 0, 1, base.specular),
    lightAngle: Number.isFinite(look.lightAngle) ? look.lightAngle : base.lightAngle,
    tint: [clamp(tint[0], 0, 1, 1), clamp(tint[1], 0, 1, 1), clamp(tint[2], 0, 1, 1), clamp(tint[3], 0, 1, 0)],
    shadow: clamp(look.shadow, 0, 1, base.shadow),
    opacity: clamp(look.opacity, 0, 1, base.opacity),
  };
}

/** How far past a layer's box the engine reads the backdrop under it, CSS px: the farthest a frost
 * tap reaches (three sigmas) plus the farthest the bevel bends, plus the shadow's reach. */
export function layerReach(look: GlassLook): number {
  return Math.ceil(look.frost * 3 + look.thickness + shadowReach(look));
}

/** How far the shadow spreads past the box, CSS px. */
export function shadowReach(look: GlassLook): number {
  return look.shadow > 0 ? 24 : 0;
}

/** The pyramid level (0 = sharp, 1 = half size, ...) and blend that frost `sigma` device px reads:
 * a level-k dual-filter image is about a gaussian of sigma 1.25 * 2^k device px. */
export function frostLevel(sigma: number, levels: number): number {
  if (sigma <= 0.5) return 0;
  return Math.min(Math.max(Math.log2(sigma / 1.25), 0), levels);
}
