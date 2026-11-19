// The glass engine's GLSL (WebGL2 only; a page without WebGL2 keeps its CSS glass). Three programs:
// a copy, the dual filter's down step that builds a layer's frost pyramid, and the layer itself.
// The layer shader computes optics.ts's functions per pixel; keep them in step.

/** Levels in a frost pyramid: level k is 1 / 2^k of the scene; frost reaches ~1.25 * 2^5 = 40 px. */
export const PYRAMID_LEVELS = 5;

export const FULLSCREEN_VERTEX = `#version 300 es
precision highp float;
// One triangle covering the viewport; the scissor limits what a pass writes.
const vec2 P[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
out vec2 v_uv;
void main() {
  vec2 p = P[gl_VertexID];
  v_uv = p * 0.5 + 0.5;
  gl_Position = vec4(p, 0.0, 1.0);
}`;

export const COPY_FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D u_src;
in vec2 v_uv;
out vec4 o;
void main() { o = texture(u_src, v_uv); }`;

// The dual filter's down step (Bjorge, "Bandwidth-Efficient Rendering", SIGGRAPH 2015), the blur
// most of the swept implementations use: 5 taps to half size. Each level is about a gaussian twice
// as wide as the one before, at a quarter of the cost. The layer reads a level with a 4-tap tent,
// which stands in for the filter's up step at any frost, not only at the pyramid's own steps.
export const DOWN_FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D u_src;
uniform vec2 u_texel;
in vec2 v_uv;
out vec4 o;
void main() {
  vec2 h = u_texel * 0.5;
  vec4 sum = texture(u_src, v_uv) * 4.0;
  sum += texture(u_src, v_uv - h);
  sum += texture(u_src, v_uv + h);
  sum += texture(u_src, v_uv + vec2(h.x, -h.y));
  sum += texture(u_src, v_uv - vec2(h.x, -h.y));
  o = sum / 8.0;
}`;

/** The layer pass: one quad per layer, in device px with y down. */
export const LAYER_VERTEX = `#version 300 es
precision highp float;
uniform vec4 u_quad;
uniform vec2 u_view;
out vec2 v_p;
const vec2 C[6] = vec2[6](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));
void main() {
  vec2 p = u_quad.xy + C[gl_VertexID] * u_quad.zw;
  v_p = p;
  vec2 ndc = p / u_view * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}`;

export const LAYER_FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D u_scene;
uniform sampler2D u_p1;
uniform sampler2D u_p2;
uniform sampler2D u_p3;
uniform sampler2D u_p4;
uniform sampler2D u_p5;
uniform vec2 u_view;
uniform vec4 u_rect;      // device px: x, y, w, h
uniform vec4 u_shape;     // radius, corner exponent, bevel, thickness (device px)
uniform vec4 u_optics;    // ior, frost level (0 sharp .. ${PYRAMID_LEVELS}), saturation, dispersion
uniform vec4 u_light;     // specular, light dir x, light dir y, shadow
uniform vec4 u_tint;      // rgb, a (not premultiplied)
uniform float u_opacity;
uniform float u_shadowReach;
in vec2 v_p;
out vec4 o;

float sdShape(vec2 p, vec2 hs, float r, float n) {
  vec2 q = abs(p) - (hs - r);
  if (q.x > 0.0 && q.y > 0.0) return pow(pow(q.x, n) + pow(q.y, n), 1.0 / n) - r;
  return max(q.x, q.y) - r;
}

vec3 level(int k, vec2 uv) {
  if (k <= 0) return texture(u_scene, uv).rgb;
  if (k == 1) return texture(u_p1, uv).rgb;
  if (k == 2) return texture(u_p2, uv).rgb;
  if (k == 3) return texture(u_p3, uv).rgb;
  if (k == 4) return texture(u_p4, uv).rgb;
  return texture(u_p5, uv).rgb;
}

// Level k read as a tent: four bilinear taps half a level-k texel off the point.
vec3 tent(int k, vec2 uv) {
  if (k <= 0) return level(0, uv);
  vec2 h = exp2(float(k)) * 0.5 / u_view;
  return (level(k, uv + h) + level(k, uv - h) + level(k, uv + vec2(h.x, -h.y)) + level(k, uv - vec2(h.x, -h.y))) * 0.25;
}

// The scene under device px point p, frosted to fractional level lv (0 is sharp).
vec3 frosted(vec2 p, float lv) {
  vec2 uv = clamp(p / u_view, vec2(0.0), vec2(1.0));
  uv.y = 1.0 - uv.y;
  int k = int(floor(lv));
  float f = lv - float(k);
  vec3 a = tent(k, uv);
  if (f < 0.01 || k >= ${PYRAMID_LEVELS}) return a;
  return mix(a, tent(k + 1, uv), f);
}

float bevelHeight(float t) {
  float u = 1.0 - clamp(t, 0.0, 1.0);
  return pow(1.0 - u * u * u * u, 0.25);
}

float bevelSlope(float t) {
  float u = 1.0 - clamp(t, 0.002, 1.0);
  return pow(1.0 - u * u * u * u, -0.75) * u * u * u;
}

// optics.ts bendAt: how far inward a vertical ray entering the bevel at t lands.
float bend(float t, float bevel, float thickness, float ior) {
  if (bevel <= 0.0 || thickness <= 0.0 || ior <= 1.0 || t >= 1.0) return 0.0;
  float slope = bevelSlope(t) * thickness / bevel;
  vec3 n = normalize(vec3(slope, 0.0, 1.0));
  vec3 r = refract(vec3(0.0, 0.0, -1.0), n, 1.0 / ior);
  return (-r.x / max(-r.z, 1e-3)) * thickness * bevelHeight(t);
}

void main() {
  vec2 hs = u_rect.zw * 0.5;
  vec2 lp = v_p - (u_rect.xy + hs);
  float r = min(u_shape.x, min(hs.x, hs.y));
  float sd = sdShape(lp, hs, r, u_shape.y);

  if (sd > 0.5) {
    // Outside: only the soft shadow, a little lower than the glass, as from a light above.
    float reach = u_shadowReach;
    if (u_light.w <= 0.0 || reach <= 0.0) discard;
    float lifted = sdShape(lp - vec2(0.0, reach * 0.25), hs, r, u_shape.y);
    float a = u_light.w * 0.32 * (1.0 - smoothstep(0.0, reach, max(lifted, 0.0))) * u_opacity;
    if (a <= 0.002) discard;
    o = vec4(0.0, 0.0, 0.0, a);
    return;
  }

  float coverage = clamp(0.5 - sd, 0.0, 1.0) * u_opacity;
  float bevel = min(u_shape.z, min(hs.x, hs.y));
  float t = bevel > 0.0 ? clamp(-sd / bevel, 0.0, 1.0) : 1.0;

  // Outward normal: the shape's gradient by central difference, one device px.
  vec2 e = vec2(1.0, 0.0);
  vec2 g = vec2(
    sdShape(lp + e.xy, hs, r, u_shape.y) - sdShape(lp - e.xy, hs, r, u_shape.y),
    sdShape(lp + e.yx, hs, r, u_shape.y) - sdShape(lp - e.yx, hs, r, u_shape.y));
  vec2 n = length(g) > 1e-4 ? normalize(g) : vec2(0.0);

  float ior = u_optics.x;
  float lv = u_optics.y;
  float d = u_optics.w;
  float b = bend(t, bevel, u_shape.w, ior);
  vec3 color;
  if (d > 0.0 && b > 0.01) {
    float bR = bend(t, bevel, u_shape.w, max(ior - 0.08 * d, 1.0));
    float bB = bend(t, bevel, u_shape.w, ior + 0.08 * d);
    color = vec3(frosted(v_p - n * bR, lv).r, frosted(v_p - n * b, lv).g, frosted(v_p - n * bB, lv).b);
  } else {
    color = frosted(v_p - n * b, lv);
  }

  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = max(mix(vec3(luma), color, u_optics.z), vec3(0.0));
  color = mix(color, u_tint.rgb, u_tint.a);

  // The rim catches the light where the bevel is steep and faces it; the far rim a fainter line.
  float spec = u_light.x;
  if (spec > 0.0) {
    float steep = 1.0 - smoothstep(0.0, 0.55, t);
    float facing = dot(n, u_light.yz);
    float rim = 1.0 - smoothstep(0.0, 1.6, -sd);
    float l = pow(max(facing, 0.0), 1.6) * (0.55 * steep + 0.9 * rim)
      + pow(max(-facing, 0.0), 2.4) * 0.35 * (0.5 * steep + rim);
    // Fresnel: the steep bevel reflects a little of the sky all along it.
    l += 0.12 * steep * steep;
    color += vec3(l * spec);
  }

  o = vec4(min(color, vec3(1.0)) * coverage, coverage);
}`;
