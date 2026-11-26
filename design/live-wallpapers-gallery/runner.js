// Runs a live wallpaper's translated GLSL (build.mjs) in a WebGL2 canvas with the same Frame
// the app gives it (plans/cmux-next/live-wallpapers.md). GL puts the pixel origin at the
// bottom left; the canvas is flipped with CSS and the pointer's y is flipped to match, so a
// program sees the top-left origin it sees in Metal.

const VERTEX = `#version 300 es
void main() {
  vec2 xy = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(xy * 2.0 - 1.0, 0.0, 1.0);
}`;

// cmux-wallpaper's Frame (src/frame.rs): 104 floats, 416 bytes; its last 64 are the trail.
const FRAME_FLOATS = 104;
const TRAIL_POINTS = 16;
const TRAIL_STEP_S = 0.05;
const TRAIL_LIFE_S = 1.0;

export const THEMES = {
  dark: { paper: "#111214", ink: "#ECEBE6", dark: 1 },
  light: { paper: "#F1EFE9", ink: "#1B1B1D", dark: 0 },
};

function linear(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
}

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
  return shader;
}

export class Wallpaper {
  // wallpaper: { manifest, glsl }; options: { theme, accent, params, scale, still }
  constructor(canvas, wallpaper, options = {}) {
    this.canvas = canvas;
    this.wallpaper = wallpaper;
    this.options = options;
    canvas.style.transform = "scaleY(-1)";
    const gl = canvas.getContext("webgl2", { antialias: false, premultipliedAlpha: true, preserveDrawingBuffer: true });
    if (!gl) throw new Error("WebGL2 is not available");
    this.gl = gl;
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, wallpaper.glsl));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    this.program = program;
    gl.uniformBlockBinding(program, 0, 0);
    this.ubo = gl.createBuffer();
    gl.bindBuffer(gl.UNIFORM_BUFFER, this.ubo);
    gl.bufferData(gl.UNIFORM_BUFFER, FRAME_FLOATS * 4, gl.DYNAMIC_DRAW);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, this.ubo);
    this.data = new Float32Array(FRAME_FLOATS);
    // The pointer's recent path, newest first: cmux-wallpaper's TrailState (src/trail.rs).
    this.trail = [];
    this.pointer = { x: 0, y: 0, vx: 0, vy: 0, inside: 0, target: 0, moved: -1e9, down: 0 };
    this.activity = { level: 0, count: 0, last: -1e9, advanced: 0, has: false };
    this.frame = 0;
    this.seed = options.seed ?? Math.random();
    if (!options.still) this.listen();
  }

  listen() {
    const c = this.canvas;
    const at = (e) => {
      const r = c.getBoundingClientRect();
      return [((e.clientX - r.left) / r.width) * c.width, ((e.clientY - r.top) / r.height) * c.height];
    };
    c.addEventListener("pointermove", (e) => {
      const [x, y] = at(e);
      const now = performance.now() / 1000;
      const dt = Math.max(now - (this.lastMove ?? now), 1 / 240);
      if (this.lastMove !== undefined && now - this.lastMove < 0.25) {
        const k = 0.35;
        this.pointer.vx += ((x - this.pointer.x) / dt - this.pointer.vx) * k;
        this.pointer.vy += ((y - this.pointer.y) / dt - this.pointer.vy) * k;
      }
      Object.assign(this.pointer, { x, y, target: 1, moved: now });
      this.lastMove = now;
      this.trailMoved(x, y, now);
    });
    c.addEventListener("pointerleave", () => (this.pointer.target = 0));
    c.addEventListener("pointerdown", () => (this.pointer.down = 1));
    c.addEventListener("pointerup", () => (this.pointer.down = 0));
  }

  // A pointer move: TrailState::moved, the same rule. With fewer than 2 points, or a step or
  // more after the newest committed point, a new head shifts in; otherwise the head moves.
  trailMoved(x, y, t) {
    const ring = this.trail;
    if (ring.length < 2 || t - ring[1].t >= TRAIL_STEP_S) {
      ring.unshift({ x, y, t });
      ring.length = Math.min(ring.length, TRAIL_POINTS);
    } else {
      ring[0] = { x, y, t };
    }
  }

  // Frame.trail at `now`: TrailState::rows. The canvas is in rendered pixels already (scale 1).
  trailRows(now) {
    const rows = new Float32Array(TRAIL_POINTS * 4);
    this.trail.forEach((p, i) => {
      const age = Math.max(now - p.t, 0);
      if (age <= TRAIL_LIFE_S) rows.set([p.x, p.y, age, 1], i * 4);
    });
    return rows;
  }

  // An agent event at `t` seconds: cmux-wallpaper's ActivityState (src/frame.rs), the same numbers.
  // A burst within 0.4 s raises the level a little and is not counted.
  agentEvent(t) {
    const a = this.activity;
    if (a.has && t - a.last < 0.4) {
      a.level += (1 - a.level) * 0.05;
      return;
    }
    if (!a.has) a.advanced = t;
    a.level += (1 - a.level) * 0.3;
    a.count = (a.count + 1) % 1024;
    a.last = t;
    a.has = true;
  }

  // The gallery has no agents: a stand-in writes a burst of output every 1 to 4 seconds.
  simulateAgent(t) {
    const s = (this.agent ??= { next: 1, until: 0 });
    if (t >= s.next) {
      s.until = t + 0.2 + Math.random() * 0.6;
      s.next = t + 1 + Math.random() * 3;
    }
    if (t < s.until) this.agentEvent(t);
  }

  // `width` and `height` in points. Like the app, the canvas renders at the screen's backing
  // scale (`options.dpr`, 2 for a Retina screen) times the manifest's scale, and `size.z` is
  // that product: rendered pixels per point.
  resize(width, height) {
    const scale = this.options.scale ?? this.wallpaper.manifest.scale ?? 1;
    const dpr = this.options.dpr ?? 2;
    this.canvas.width = Math.max(1, Math.round(width * dpr * scale));
    this.canvas.height = Math.max(1, Math.round(height * dpr * scale));
    this.backing = dpr * scale;
  }

  // One frame at `time` seconds. A still passes its pointer as fractions of the size.
  draw(time, dt = 1 / 30) {
    const { gl, canvas, data, pointer, options } = this;
    const manifest = this.wallpaper.manifest;
    const theme = THEMES[options.theme ?? "dark"];
    const accent = linear(options.accent ?? "#3D7BFF");
    if (options.still) {
      const p = options.pointer ?? manifest.still?.pointer ?? [0.6, 0.4];
      Object.assign(pointer, { x: p[0] * canvas.width, y: p[1] * canvas.height, vx: 0, vy: 0, inside: 1, moved: 0 });
    } else {
      pointer.inside += (pointer.target - pointer.inside) * Math.min(1, dt * 6);
      pointer.vx *= Math.exp(-dt * 4);
      pointer.vy *= Math.exp(-dt * 4);
    }
    const params = (manifest.params ?? []).map((p) => options.params?.[p.name] ?? p.default);
    const sinceMove = options.still ? 10 : performance.now() / 1000 - pointer.moved;
    data.set([time, dt, this.frame, options.still ? 1 : 0], 0);
    data.set([canvas.width, canvas.height, this.backing ?? 1, this.seed], 4);
    data.set([pointer.x, pointer.y, pointer.vx, pointer.vy], 8);
    data.set([pointer.inside, Math.min(sinceMove, 1e4), pointer.down, theme.dark], 12);
    data.set([...linear(theme.ink), 1], 16);
    data.set([...linear(theme.paper), 1], 20);
    data.set([...accent, 1], 24);
    data.fill(0, 28);
    data.set(params.slice(0, 8), 28);
    const a = this.activity;
    if (!options.still) {
      a.level *= Math.exp(-0.35 * Math.max(0, time - a.advanced));
      if (a.level < 1e-3) a.level = 0;
      a.advanced = time;
    }
    const sinceAgent = a.has ? Math.min(Math.max(time - a.last, 0), 1e4) : 1e4;
    data.set([a.level, sinceAgent, a.count, 0], 36);
    // A still has no trail (the program draws its own); a live frame has the pointer's.
    if (!options.still) data.set(this.trailRows(performance.now() / 1000), 40);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.useProgram(this.program);
    gl.bindBuffer(gl.UNIFORM_BUFFER, this.ubo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, data);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    this.frame += 1;
  }

  // Runs at `fps` until stop() is called. The gallery stops a card that scrolls out of view.
  start(fps = this.wallpaper.manifest.fps ?? 30) {
    const interval = 1000 / fps;
    let last = 0;
    const t0 = performance.now();
    const tick = (now) => {
      this.raf = requestAnimationFrame(tick);
      if (now - last < interval - 1) return;
      const dt = last ? (now - last) / 1000 : 1 / fps;
      last = now;
      const time = (now - t0) / 1000;
      if (this.wallpaper.manifest.agents) this.simulateAgent(time);
      this.draw(time, dt);
    };
    this.raf = requestAnimationFrame(tick);
  }

  stop() {
    cancelAnimationFrame(this.raf);
  }

  // Gives the GL context back: a browser keeps only about 16 at once.
  dispose() {
    this.stop();
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }
}
