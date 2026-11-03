// A live background (experiment live-background, liveBackground.experiment.ts): a slow, GPU-cheap
// shader behind the page's content, in the place of the still picture "Set Background…" shows.
// Leo, 2026-11-01: "but also we literally have backgrounds embedde inside today".
//
// Cost: one WebGL canvas at --layer-backdrop drawn at half the CSS resolution (the picture is soft,
// so nothing is lost) and at most 30 frames a second; one fragment shader with no texture reads.
// The page's own glass (glass.css) frosts it like any page pixels, and the lens stands down while it
// runs (data-live-background: the lens would draw the host's still over it).
//
// Stop conditions: the loop runs only while the page is shown and the person has used it in the last
// IDLE_MS; hidden or idle, it stops after drawing nothing more (the last frame stays), and the next
// input or show starts it again. Motion off or Reduce Motion: one still frame, no loop. A lost WebGL
// context: no background. uninstall() cancels the frame, removes every listener and the canvas, and
// releases the context.

import { LIVE_BACKGROUND_ATTRIBUTE } from "../glass/glassState";

export type LiveBackgroundStyle = "aurora" | "drift" | "grain";

/** No input for this long and the loop stops until the next one. */
export const IDLE_MS = 30_000;
/** At most this many frames a second. */
export const MAX_FPS = 30;
/** The canvas's resolution against the CSS pixel. */
export const RESOLUTION = 0.5;

const STYLE_INDEX: Record<LiveBackgroundStyle, number> = { aurora: 0, drift: 1, grain: 2 };
const INPUTS = ["pointermove", "pointerdown", "keydown", "wheel"] as const;

const VERTEX = `attribute vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }`;

const FRAGMENT = `precision highp float;
uniform vec2 u_size;
uniform float u_time;
uniform float u_style;
uniform float u_dark;
uniform vec3 u_accent;

vec3 palette(float t, vec3 a, vec3 b, vec3 c) {
  return mix(mix(a, b, smoothstep(0.0, 0.6, t)), c, smoothstep(0.5, 1.0, t));
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_size;
  float aspect = u_size.x / max(u_size.y, 1.0);
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = u_time;
  vec3 deep = mix(vec3(0.93, 0.94, 0.97), vec3(0.04, 0.05, 0.09), u_dark);
  vec3 mid = mix(vec3(0.80, 0.84, 0.96), vec3(0.10, 0.12, 0.28), u_dark);
  vec3 hot = mix(u_accent * 0.6 + 0.4, u_accent * 0.85, u_dark);
  vec3 color;
  if (u_style < 0.5) {
    // Aurora: bands that sway and fold slowly over a deep field.
    float band = 0.0;
    for (int i = 0; i < 3; i++) {
      float fi = float(i);
      float y = 0.55 + 0.12 * sin(p.x * (1.3 + fi * 0.7) + t * (0.11 + fi * 0.05) + fi * 2.1)
                     + 0.05 * sin(p.x * 3.7 - t * 0.17 + fi);
      float d = (uv.y - y + fi * 0.09) * (7.0 + fi * 3.0);
      band += exp(-d * d) * (0.7 - fi * 0.18);
    }
    color = mix(deep, mid, uv.y * 0.6);
    color = mix(color, hot, clamp(band, 0.0, 1.0) * 0.75);
  } else {
    // Drift (and Grain): four soft blobs of the palette that wander, a mesh gradient in motion.
    vec2 c0 = vec2(0.3 * aspect + 0.15 * sin(t * 0.07), 0.3 + 0.12 * cos(t * 0.09));
    vec2 c1 = vec2(0.75 * aspect + 0.12 * cos(t * 0.06), 0.7 + 0.1 * sin(t * 0.08));
    vec2 c2 = vec2(0.6 * aspect + 0.2 * sin(t * 0.05 + 1.0), 0.2 + 0.15 * sin(t * 0.07 + 2.0));
    vec2 c3 = vec2(0.2 * aspect + 0.1 * cos(t * 0.08 + 3.0), 0.8 + 0.1 * cos(t * 0.05));
    float w0 = 1.0 / (0.02 + dot(p - c0, p - c0));
    float w1 = 1.0 / (0.02 + dot(p - c1, p - c1));
    float w2 = 1.0 / (0.02 + dot(p - c2, p - c2));
    float w3 = 1.0 / (0.02 + dot(p - c3, p - c3));
    vec3 warm = mix(vec3(0.98, 0.80, 0.70), vec3(0.45, 0.12, 0.30), u_dark);
    color = (deep * w0 + hot * w1 + mid * w2 + warm * w3) / (w0 + w1 + w2 + w3);
    if (u_style > 1.5) {
      // Grain: a fine film grain that changes with each frame, under 3% so text stays clean.
      color += (hash(gl_FragCoord.xy + fract(t) * 91.0) - 0.5) * 0.05;
    }
  }
  gl_FragColor = vec4(color, 1.0);
}`;

type Gpu = {
  gl: WebGLRenderingContext;
  uniforms: Record<"u_size" | "u_time" | "u_style" | "u_dark" | "u_accent", WebGLUniformLocation | null>;
};

function createGpu(canvas: HTMLCanvasElement): Gpu | null {
  const gl = canvas.getContext("webgl", {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    preserveDrawingBuffer: false,
    powerPreference: "low-power",
  });
  if (!gl) return null;
  const shader = (type: number, source: string) => {
    const handle = gl.createShader(type);
    if (!handle) return null;
    gl.shaderSource(handle, source);
    gl.compileShader(handle);
    return gl.getShaderParameter(handle, gl.COMPILE_STATUS) ? handle : null;
  };
  const vertex = shader(gl.VERTEX_SHADER, VERTEX);
  const fragment = shader(gl.FRAGMENT_SHADER, FRAGMENT);
  const program = gl.createProgram();
  // A failed setup releases the context now rather than at garbage collection.
  const fail = () => {
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return null;
  };
  if (!vertex || !fragment || !program) return fail();
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.bindAttribLocation(program, 0, "a_pos");
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return fail();
  gl.useProgram(program);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const uniforms = {
    u_size: gl.getUniformLocation(program, "u_size"),
    u_time: gl.getUniformLocation(program, "u_time"),
    u_style: gl.getUniformLocation(program, "u_style"),
    u_dark: gl.getUniformLocation(program, "u_dark"),
    u_accent: gl.getUniformLocation(program, "u_accent"),
  };
  return { gl, uniforms };
}

/** Whether the host or the system asks for no motion (a still frame instead of the loop). */
function stillOnly(doc: Document): boolean {
  const motion = doc.documentElement.dataset.cmuxMotion;
  return (
    motion === "off" ||
    motion === "reduced" ||
    doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true
  );
}

/** The accent as linear-ish 0..1 RGB, read through one probe; the theme's blue when unreadable. */
function readAccent(doc: Document): [number, number, number] {
  const probe = doc.createElement("span");
  probe.style.cssText =
    "position:absolute;width:0;height:0;visibility:hidden;color:var(--cmux-accent, rgb(90 120 255))";
  doc.documentElement.append(probe);
  const match = doc.defaultView?.getComputedStyle(probe).color.match(/[\d.]+/g);
  probe.remove();
  if (!match || match.length < 3) return [0.35, 0.47, 1];
  return [Number(match[0]) / 255, Number(match[1]) / 255, Number(match[2]) / 255];
}

export type LiveBackground = {
  /** Frames drawn so far (tests and the harness read it). */
  readonly frames: () => number;
  /** Whether the loop is running now (not hidden, not idle, motion allowed). */
  readonly running: () => boolean;
  uninstall(): void;
};

/** Starts a live background of `style` behind the document's content. */
export function installLiveBackground(doc: Document, style: LiveBackgroundStyle): LiveBackground | null {
  const view = doc.defaultView;
  if (!view) return null;
  const root = doc.documentElement;
  const canvas = doc.createElement("canvas");
  canvas.setAttribute("aria-hidden", "true");
  canvas.dataset.cmuxLiveBackground = style;
  canvas.style.cssText =
    "position:fixed;inset:0;width:100%;height:100%;z-index:var(--layer-backdrop, -1);pointer-events:none;contain:strict;";
  const gpu = createGpu(canvas);
  if (!gpu) return null;
  const { gl, uniforms } = gpu;
  root.prepend(canvas);
  root.setAttribute(LIVE_BACKGROUND_ATTRIBUTE, style);

  let frame = 0;
  let frames = 0;
  let lastDraw = 0;
  let lastInput = view.performance.now();
  let lost = false;
  // The shader's clock runs only while the loop does, so a paused background resumes where it was.
  let clock = 0;
  let clockFrom = 0;
  const accent = readAccent(doc);
  // The page's scheme as the host set it (data-theme, WebTheme.swift), else the system's.
  const dark = () => {
    const theme = root.dataset.theme;
    if (theme === "light" || theme === "dark") return theme === "dark";
    return view.matchMedia?.("(prefers-color-scheme: light)").matches !== true;
  };

  const resize = () => {
    const width = Math.max(1, Math.round(root.clientWidth * RESOLUTION));
    const height = Math.max(1, Math.round(root.clientHeight * RESOLUTION));
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
  };
  const draw = (seconds: number) => {
    if (lost) return;
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(uniforms.u_size, canvas.width, canvas.height);
    gl.uniform1f(uniforms.u_time, seconds);
    gl.uniform1f(uniforms.u_style, STYLE_INDEX[style]);
    gl.uniform1f(uniforms.u_dark, dark() ? 1 : 0);
    gl.uniform3f(uniforms.u_accent, accent[0], accent[1], accent[2]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    frames++;
  };
  const allowed = () => !lost && !doc.hidden && !stillOnly(doc) && view.performance.now() - lastInput < IDLE_MS;
  /** The shader's time now: the paused clock plus the running stretch. */
  const elapsed = (now: number) => clock + (frame ? (now - clockFrom) / 1000 : 0);
  const tick = (now: number) => {
    if (!allowed()) {
      // Idle, hidden or motion off: the clock keeps what ran, so the next start resumes from here.
      clock += (now - clockFrom) / 1000;
      frame = 0;
      return;
    }
    frame = 0;
    if (now - lastDraw >= 1000 / MAX_FPS - 1) {
      lastDraw = now;
      draw(clock + (now - clockFrom) / 1000);
    }
    frame = view.requestAnimationFrame(tick);
  };
  const start = () => {
    if (frame || !allowed()) return;
    clockFrom = view.performance.now();
    frame = view.requestAnimationFrame(tick);
  };
  const pause = () => {
    if (!frame) return;
    view.cancelAnimationFrame(frame);
    frame = 0;
    clock += (view.performance.now() - clockFrom) / 1000;
  };
  const onInput = () => {
    lastInput = view.performance.now();
    start();
  };
  const onVisibility = () => (doc.hidden ? pause() : start());
  const onResize = () => {
    resize();
    draw(elapsed(view.performance.now()));
  };
  const onLost = (event: Event) => {
    event.preventDefault();
    lost = true;
    pause();
  };
  for (const kind of INPUTS) view.addEventListener(kind, onInput, { passive: true, capture: true });
  doc.addEventListener("visibilitychange", onVisibility);
  view.addEventListener("resize", onResize);
  canvas.addEventListener("webglcontextlost", onLost);
  resize();
  // The first frame always draws (the still under Reduce Motion), then the loop if it may run.
  draw(0);
  start();

  return {
    frames: () => frames,
    running: () => frame !== 0,
    uninstall() {
      pause();
      for (const kind of INPUTS) view.removeEventListener(kind, onInput, { capture: true });
      doc.removeEventListener("visibilitychange", onVisibility);
      view.removeEventListener("resize", onResize);
      canvas.removeEventListener("webglcontextlost", onLost);
      gl.getExtension("WEBGL_lose_context")?.loseContext();
      canvas.remove();
      root.removeAttribute(LIVE_BACKGROUND_ATTRIBUTE);
    },
  };
}
