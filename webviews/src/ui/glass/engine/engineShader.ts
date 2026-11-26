// The glass engine's shaders (engineRenderer.ts has the wiring): the lens's geometry
// (lens.ts) with a real glass surface under it. Each `.ui-glass` rounded rect is a convex slab whose
// height rises from its rim along a superellipse; a ray from the eye refracts through that surface
// (Snell's law, index u_ior) and lands on the wallpaper still, so the rim compresses and bends what
// is behind it while the flat middle stays true. Over that: a Fresnel term and a two-light specular
// rim whose key light follows the pointer near the glass, an adaptive veil that adds the theme's
// surface only where the backdrop under the glass would fight the text color, and a per-surface
// motion energy (the glass moved) that flexes the bend and lights the rim for a moment.
//
// Cost: the wallpaper's own blur is done once per still in two prefilter passes (PREFILTER_*), not
// per pixel per frame, so every glass pixel reads ONE texel (three on the rim under a dispersion),
// plus five coarse texels per pixel for the adaptive veil, where the lens's frost read nine (27 under
// Spectrum). The margin copy reads one.
//
// The vertex layout is the lens's (lens.ts VERTEX); a_extra.w, unused by the lens, carries motion.

// The engine fragment shader. Its inputs are the lens's (lens.ts measure) plus ENGINE_UNIFORMS.
export const ENGINE_FRAGMENT = `
uniform sampler2D u_tex;
uniform vec4 u_art;
uniform vec2 u_texSize;
uniform vec4 u_tint;
uniform vec4 u_surface;
uniform vec3 u_veil;
uniform vec3 u_ink;
uniform float u_adapt;
uniform float u_pass;
uniform float u_margin;
uniform float u_dpr;
uniform float u_ior;
uniform vec3 u_pointer;
VARY vec2 v_p;
VARY vec4 v_rect;
VARY vec4 v_clip;
VARY vec4 v_shape;
VARY vec4 v_extra;
OUT_DECL

float sdRound(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - (b - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 tap(vec2 p, float lod) {
  vec2 uv = clamp((p - u_art.xy) / u_art.zw, vec2(0.0), vec2(1.0));
  return SAMPLE(u_tex, uv, lod).rgb;
}

// The mip level whose footprint reads like a gaussian of sigma CSS px over the prefiltered still.
float lodFor(float sigma) {
  float texels = sigma * u_texSize.x / u_art.z;
  return texels < 0.6 ? 0.0 : log2(texels * 2.5);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
  vec2 halfSize = v_rect.zw * 0.5;
  vec2 center = v_rect.xy + halfSize;
  vec2 lp = v_p - center;
  float minHalf = min(halfSize.x, halfSize.y);
  float r = min(v_shape.x, minHalf);
  float sd = sdRound(lp, halfSize, r);
  bool inClip = v_p.x >= v_clip.x && v_p.y >= v_clip.y && v_p.x < v_clip.z && v_p.y < v_clip.w;
  if (u_pass < 0.5) {
    // The copy around the glass, fading out: what is already under the page (one texel).
    if (inClip && sd < 0.0) discard;
    float fade = 1.0 - smoothstep(0.0, u_margin, max(sd, 0.0));
    if (fade <= 0.0) discard;
    vec3 around = mix(tap(v_p, 0.0), u_tint.rgb, u_tint.a);
    around = mix(around, u_surface.rgb, u_surface.a);
    OUT_COLOR = vec4(around * fade, fade);
    return;
  }
  if (!inClip || sd >= 0.0) discard;
  float alpha = clamp(-sd * u_dpr, 0.0, 1.0) * v_extra.x;
  float energy = v_extra.w;
  // The slab: refraction (CSS px) is its thickness; the rim band is where its height rises.
  float thickness = v_shape.y * (1.0 + 0.25 * energy);
  float band = min(minHalf, max(thickness * 2.6, 10.0));
  float t = clamp(-sd / band, 0.0, 1.0);
  // Convex superellipse height h = (1 - (1 - t)^3)^(1/3), and its slope dh/dt: steep at the rim,
  // flat a third of the band in, so the bend is a rim, not a bowl.
  float k = 1.0 - t;
  float k3 = k * k * k;
  float h = pow(max(1.0 - k3, 1e-4), 1.0 / 3.0);
  float slope = k * k * pow(max(1.0 - k3, 1e-3), -2.0 / 3.0);
  // The outward edge normal of the same box with a corner no smaller than the band (no seam).
  float rn = min(max(r, band), minHalf);
  vec2 q = abs(lp) - (halfSize - rn);
  vec2 n = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
  n *= vec2(lp.x < 0.0 ? -1.0 : 1.0, lp.y < 0.0 ? -1.0 : 1.0);
  // The surface normal: the height falls toward the rim, so it tips outward by the slope.
  vec3 N = normalize(vec3(n * min(slope * 1.2, 6.0), 1.0));
  // Snell: the eye ray (straight in) bends at the surface and crosses the slab to the back face.
  vec3 R = refract(vec3(0.0, 0.0, -1.0), N, 1.0 / u_ior);
  // The ray crosses more glass at the rim than in the middle; at the very rim it shifts about
  // the thickness, a third of the band in about a fifth of it.
  float depth = thickness * (1.3 - 0.7 * h);
  vec2 shift = R.xy / max(-R.z, 0.2) * depth;
  // Lensing: the middle reads the wallpaper a little closer, as a thick lens does.
  vec2 base = v_p - lp * (v_extra.z + 0.02 * energy);
  float sigma = v_shape.z;
  float lod = lodFor(sigma);
  vec2 at = base + shift;
  vec3 color;
  float d = v_shape.w;
  if (d > 0.0 && t < 1.0) {
    // Dispersion on the rim only: each channel refracts by its own index.
    color = vec3(tap(base + shift * (1.0 - d), lod).r, tap(at, lod).g, tap(base + shift * (1.0 + d), lod).b);
  } else {
    color = tap(at, lod);
  }
  color = mix(color, u_tint.rgb, u_tint.a);
  color = mix(color, u_surface.rgb, u_surface.a);
  // Adaptive veil: the backdrop under this glass against the text color; where they are close, the
  // theme's surface comes up under the text, else it stays clear. The worst of five coarse texels
  // (the middle and each quadrant's middle), not one average of the whole glass: the glass lab
  // (2026-11-19, b8cadc3c) found a dark average leaving the veil at 4% over bright swirls that set
  // the worst text pixel (selected rows 3.90:1 over a bright painting, 4.02:1 over a dark one).
  vec2 lodSpan = v_rect.zw * u_texSize / u_art.zw;
  float quarterLod = log2(max(max(lodSpan.x, lodSpan.y) * 0.5, 1.0)) - 1.0;
  float inkLuma = luma(u_ink);
  float gap = abs(luma(mix(tap(center, quarterLod + 1.0), u_tint.rgb, u_tint.a)) - inkLuma);
  vec2 quad = halfSize * 0.5;
  gap = min(gap, abs(luma(mix(tap(center + vec2(-quad.x, -quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(quad.x, -quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(-quad.x, quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  gap = min(gap, abs(luma(mix(tap(center + vec2(quad.x, quad.y), quarterLod), u_tint.rgb, u_tint.a)) - inkLuma));
  float veil = u_adapt * clamp((0.62 - gap) / 0.42, 0.0, 1.0);
  color = mix(color, u_veil, veil);
  // Light: a key light (above, a little left, swung toward the pointer when it is near this glass)
  // and a fainter fill from the far side, on a band at the rim; a Fresnel sheen where the slab tilts.
  float gloss = v_extra.y;
  if (gloss > 0.0) {
    vec2 key = normalize(vec2(-0.42, -1.0));
    vec2 toPointer = u_pointer.xy - center;
    float near = u_pointer.z * (1.0 - smoothstep(minHalf, minHalf + 420.0, length(toPointer)));
    if (near > 0.0 && dot(toPointer, toPointer) > 1.0) key = normalize(mix(key, normalize(toPointer), near));
    float facing = dot(n, key);
    float rimWidth = max(1.5, min(band * 0.32, 6.0));
    float rim = 1.0 - smoothstep(0.0, rimWidth, -sd);
    float fresnel = pow(1.0 - N.z, 2.0);
    float light = pow(max(facing, 0.0), 1.6) + 0.35 * pow(max(-facing, 0.0), 2.5);
    float lit = (rim * light * 0.7 + fresnel * (0.18 + 0.22 * max(facing, 0.0))) * gloss * (1.0 + 0.6 * energy);
    color += vec3(lit);
    // The far side of the rim shades a little, so the rim reads on a bright backdrop too.
    color *= 1.0 - rim * 0.12 * max(-facing, 0.0) * gloss;
  }
  OUT_COLOR = vec4(min(color, vec3(1.0)) * alpha, alpha);
}`;

/** The prefilter's vertex shader: one full-target triangle pair, uv in [0, 1]. */
export const PREFILTER_VERTEX = `
ATTR vec2 a_pos;
VARY vec2 v_uv;
void main() {
  v_uv = a_pos;
  gl_Position = vec4(a_pos * 2.0 - 1.0, 0.0, 1.0);
}`;

/** One direction of a separable gaussian, seven bilinear taps (13 texels) at u_step apart. */
export const PREFILTER_FRAGMENT = `
uniform sampler2D u_src;
uniform vec2 u_step;
uniform float u_lod;
VARY vec2 v_uv;
OUT_DECL
void main() {
  vec3 sum = SAMPLE(u_src, v_uv, u_lod).rgb * 0.2270;
  sum += (SAMPLE(u_src, v_uv + u_step, u_lod).rgb + SAMPLE(u_src, v_uv - u_step, u_lod).rgb) * 0.1945;
  sum += (SAMPLE(u_src, v_uv + 2.0 * u_step, u_lod).rgb + SAMPLE(u_src, v_uv - 2.0 * u_step, u_lod).rgb) * 0.1216;
  sum += (SAMPLE(u_src, v_uv + 3.0 * u_step, u_lod).rgb + SAMPLE(u_src, v_uv - 3.0 * u_step, u_lod).rgb) * 0.0541;
  OUT_COLOR = vec4(sum / 0.9674, 1.0);
}`;
