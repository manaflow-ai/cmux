// Runs a live wallpaper's translated GLSL (build.mjs) in a WebGL2 canvas with the same Frame
// the app gives it (plans/cmux-next/live-wallpapers.md). GL puts the pixel origin at the
// bottom left; the canvas is flipped with CSS and the pointer's y is flipped to match, so a
// program sees the top-left origin it sees in Metal.

const VERTEX = `#version 300 es
void main() {
  vec2 xy = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(xy * 2.0 - 1.0, 0.0, 1.0);
}`;

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
    gl.bufferData(gl.UNIFORM_BUFFER, 144, gl.DYNAMIC_DRAW);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, this.ubo);
    this.data = new Float32Array(36);
    this.pointer = { x: 0, y: 0, vx: 0, vy: 0, inside: 0, target: 0, moved: -1e9, down: 0 };
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
    });
    c.addEventListener("pointerleave", () => (this.pointer.target = 0));
    c.addEventListener("pointerdown", () => (this.pointer.down = 1));
    c.addEventListener("pointerup", () => (this.pointer.down = 0));
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
      this.draw((now - t0) / 1000, dt);
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
