// The glass engine (design/glass.md, "Glass engine"): one WebGL2 renderer for Liquid Glass that
// every glass prototype draws with, instead of each writing its own. It knows nothing of the DOM:
// a caller gives it a canvas, a backdrop and a list of layers in CSS px, and it draws them.
//
// A frame: the backdrop goes into the scene; then, bottom layer first, each layer copies the scene
// under it (its box plus how far its frost and bend reach), builds a frost pyramid from that copy
// with the dual filter's down step, and draws itself into the scene, so a layer above another
// refracts and frosts the glass below it, not only the backdrop. The output is the whole scene, or
// (over a see-through page whose real backdrop is native, behind it) only the layers' boxes.
//
// Cost scales with the layers' area, not the canvas: each layer's copy, pyramid and draw are
// scissored to its reach. The scene copy of the backdrop is the one full-canvas pass.
import {
  PYRAMID_LEVELS,
  COPY_FRAGMENT,
  DOWN_FRAGMENT,
  FULLSCREEN_VERTEX,
  LAYER_FRAGMENT,
  LAYER_VERTEX,
} from "./shaders";
import { frostLevel, layerReach, resolveLook, shadowReach, type GlassLook } from "./optics";

/** One glass on the canvas: its box in CSS px from the canvas's top left, and its look. */
export type GlassLayer = {
  x: number;
  y: number;
  width: number;
  height: number;
  look?: Partial<GlassLook>;
};

/** Where the backdrop image sits on the canvas, CSS px; null fills the canvas. */
export type BackdropPlacement = { x: number; y: number; width: number; height: number } | null;

/** "scene": the backdrop with the glass on it. "layers": only each layer's box (and shadow), clear
 * elsewhere, for a canvas over a backdrop the page does not draw itself. */
export type GlassOutput = "scene" | "layers";

export type GlassFrameStats = {
  /** CPU time the last render() took to issue its work, ms. */
  cpuMs: number;
  /** Device px the layers' passes covered (copy, pyramid and draw), summed. */
  layerPixels: number;
  layers: number;
};

type Target = { framebuffer: WebGLFramebuffer; texture: WebGLTexture; width: number; height: number };
type Programs = {
  copy: WebGLProgram;
  down: WebGLProgram;
  layer: WebGLProgram;
  uniforms: Map<WebGLProgram, Map<string, WebGLUniformLocation | null>>;
};
type Box = { x: number; y: number; w: number; h: number };

function compile(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader {
  const shader = gl.createShader(type);
  if (!shader) throw new Error("glass engine: createShader");
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS) && !gl.isContextLost())
    throw new Error(`glass engine: shader: ${gl.getShaderInfoLog(shader) ?? ""}`);
  return shader;
}

function link(gl: WebGL2RenderingContext, vertex: string, fragment: string): WebGLProgram {
  const program = gl.createProgram();
  if (!program) throw new Error("glass engine: createProgram");
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertex));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragment));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS) && !gl.isContextLost())
    throw new Error(`glass engine: link: ${gl.getProgramInfoLog(program) ?? ""}`);
  return program;
}

/** Clips a box to the canvas, rounding out to whole device px; null when nothing is left. */
function clipBox(box: Box, width: number, height: number): Box | null {
  const x0 = Math.max(0, Math.floor(box.x));
  const y0 = Math.max(0, Math.floor(box.y));
  const x1 = Math.min(width, Math.ceil(box.x + box.w));
  const y1 = Math.min(height, Math.ceil(box.y + box.h));
  return x1 > x0 && y1 > y0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
}

export class GlassEngine {
  readonly canvas: HTMLCanvasElement | OffscreenCanvas;
  private readonly gl: WebGL2RenderingContext;
  private programs: Programs | null = null;
  private vao: WebGLVertexArrayObject | null = null;
  private backdrop: WebGLTexture | null = null;
  private hasBackdrop = false;
  private placement: BackdropPlacement = null;
  private scene: Target | null = null;
  private snapshot: Target | null = null;
  private pyramid: Target[] = [];
  private width = 0;
  private height = 0;
  private dpr = 1;
  private lost = false;
  stats: GlassFrameStats = { cpuMs: 0, layerPixels: 0, layers: 0 };

  private constructor(canvas: HTMLCanvasElement | OffscreenCanvas, gl: WebGL2RenderingContext) {
    this.canvas = canvas;
    this.gl = gl;
    this.init();
    canvas.addEventListener("webglcontextlost", this.onLost as EventListener);
    canvas.addEventListener("webglcontextrestored", this.onRestored as EventListener);
  }

  /** An engine on `canvas`, or null where WebGL2 is missing (the caller keeps its CSS glass). */
  static create(canvas: HTMLCanvasElement | OffscreenCanvas): GlassEngine | null {
    const gl = canvas.getContext("webgl2", {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
      powerPreference: "high-performance",
    }) as WebGL2RenderingContext | null;
    if (!gl) return null;
    try {
      return new GlassEngine(canvas, gl);
    } catch (error) {
      console.warn("cmux glass engine:", error);
      return null;
    }
  }

  /** Whether the context is lost; render() draws nothing until it is restored. */
  get isLost(): boolean {
    return this.lost;
  }

  private readonly onLost = (event: Event) => {
    event.preventDefault();
    this.lost = true;
  };

  private readonly onRestored = () => {
    this.lost = false;
    this.programs = null;
    this.scene = this.snapshot = null;
    this.pyramid = [];
    this.backdrop = null;
    this.hasBackdrop = false;
    this.init();
    const { width, height, dpr } = this;
    this.width = this.height = 0;
    this.resize(width / dpr, height / dpr, dpr);
  };

  private init(): void {
    const gl = this.gl;
    const copy = link(gl, FULLSCREEN_VERTEX, COPY_FRAGMENT);
    const down = link(gl, FULLSCREEN_VERTEX, DOWN_FRAGMENT);
    const layer = link(gl, LAYER_VERTEX, LAYER_FRAGMENT);
    const uniforms = new Map<WebGLProgram, Map<string, WebGLUniformLocation | null>>();
    for (const program of [copy, down, layer]) uniforms.set(program, new Map());
    this.programs = { copy, down, layer, uniforms };
    // gl_VertexID draws need a bound vertex array, with no attributes.
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    gl.useProgram(layer);
    const units: Record<string, number> = { u_scene: 0, u_p1: 1, u_p2: 2, u_p3: 3, u_p4: 4, u_p5: 5 };
    for (const [name, unit] of Object.entries(units)) gl.uniform1i(this.uniform(layer, name), unit);
    this.backdrop = this.texture();
    gl.disable(gl.DEPTH_TEST);
  }

  private uniform(program: WebGLProgram, name: string): WebGLUniformLocation | null {
    const table = this.programs!.uniforms.get(program)!;
    if (!table.has(name)) table.set(name, this.gl.getUniformLocation(program, name));
    return table.get(name) ?? null;
  }

  private texture(): WebGLTexture {
    const gl = this.gl;
    const texture = gl.createTexture();
    if (!texture) throw new Error("glass engine: createTexture");
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return texture;
  }

  private target(width: number, height: number, old: Target | null): Target {
    const gl = this.gl;
    if (old && old.width === width && old.height === height) return old;
    if (old) {
      gl.deleteFramebuffer(old.framebuffer);
      gl.deleteTexture(old.texture);
    }
    const texture = this.texture();
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    const framebuffer = gl.createFramebuffer();
    if (!framebuffer) throw new Error("glass engine: createFramebuffer");
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    return { framebuffer, texture, width, height };
  }

  /** Sizes the canvas to `cssWidth` x `cssHeight` CSS px at `dpr` device px each. */
  resize(cssWidth: number, cssHeight: number, dpr: number): void {
    const width = Math.max(1, Math.round(cssWidth * dpr));
    const height = Math.max(1, Math.round(cssHeight * dpr));
    this.dpr = dpr;
    if (width === this.width && height === this.height) return;
    this.width = this.canvas.width = width;
    this.height = this.canvas.height = height;
    if (this.lost) return;
    this.scene = this.target(width, height, this.scene);
    this.snapshot = this.target(width, height, this.snapshot);
    for (let k = 1; k <= PYRAMID_LEVELS; k++)
      this.pyramid[k - 1] = this.target(
        Math.max(1, Math.ceil(width / 2 ** k)),
        Math.max(1, Math.ceil(height / 2 ** k)),
        this.pyramid[k - 1] ?? null,
      );
  }

  /** The picture under the glass, placed at `placement` (null fills the canvas); null clears it. */
  setBackdrop(source: TexImageSource | null, placement: BackdropPlacement = null): void {
    this.placement = placement;
    if (this.lost || !this.backdrop) return;
    const gl = this.gl;
    if (!source) {
      this.hasBackdrop = false;
      return;
    }
    gl.bindTexture(gl.TEXTURE_2D, this.backdrop);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, source);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    this.hasBackdrop = true;
  }

  /** Draws one frame: the backdrop, then `layers` bottom first. */
  // perf-hot: 4ms glass-engine.render
  render(layers: readonly GlassLayer[], output: GlassOutput = "scene"): void {
    const started = performance.now();
    const gl = this.gl;
    const scene = this.scene;
    const snapshot = this.snapshot;
    const programs = this.programs;
    if (this.lost || !scene || !snapshot || !programs) return;
    const { width, height, dpr } = this;
    gl.bindVertexArray(this.vao);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.BLEND);

    // The backdrop into the scene.
    gl.bindFramebuffer(gl.FRAMEBUFFER, scene.framebuffer);
    gl.viewport(0, 0, width, height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (this.hasBackdrop) this.drawBackdrop(programs.copy);

    let layerPixels = 0;
    const boxes: Box[] = [];
    gl.enable(gl.SCISSOR_TEST);
    for (const layer of layers) {
      const look = resolveLook(layer.look);
      if (look.opacity <= 0 || layer.width <= 0 || layer.height <= 0) continue;
      const rect = { x: layer.x * dpr, y: layer.y * dpr, w: layer.width * dpr, h: layer.height * dpr };
      const reach = layerReach(look) * dpr;
      const region = clipBox(
        { x: rect.x - reach, y: rect.y - reach, w: rect.w + 2 * reach, h: rect.h + 2 * reach },
        width,
        height,
      );
      if (!region) continue;
      const shadow = shadowReach(look) * dpr;
      const drawn = clipBox(
        { x: rect.x - shadow, y: rect.y - shadow, w: rect.w + 2 * shadow, h: rect.h + 2 * shadow },
        width,
        height,
      );
      if (!drawn) continue;
      boxes.push(drawn);
      const levels = Math.ceil(frostLevel(look.frost * dpr, PYRAMID_LEVELS));
      layerPixels += this.prepare(region, scene, snapshot, levels, programs.down) + drawn.w * drawn.h;
      this.drawLayer(programs.layer, rect, drawn, look, snapshot, levels);
    }

    // The output.
    gl.disable(gl.BLEND);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, scene.framebuffer);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    if (output === "scene") {
      gl.disable(gl.SCISSOR_TEST);
      gl.blitFramebuffer(0, 0, width, height, 0, 0, width, height, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    } else {
      gl.disable(gl.SCISSOR_TEST);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      for (const box of boxes) {
        const y = height - box.y - box.h;
        gl.blitFramebuffer(
          box.x,
          y,
          box.x + box.w,
          y + box.h,
          box.x,
          y,
          box.x + box.w,
          y + box.h,
          gl.COLOR_BUFFER_BIT,
          gl.NEAREST,
        );
      }
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    this.stats = { cpuMs: performance.now() - started, layerPixels, layers: boxes.length };
  }

  private drawBackdrop(copy: WebGLProgram): void {
    const gl = this.gl;
    gl.useProgram(copy);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.backdrop);
    gl.uniform1i(this.uniform(copy, "u_src"), 0);
    const p = this.placement;
    if (p) {
      // The placement in GL px (y up); the copy's full-canvas triangle draws only inside it.
      const x = p.x * this.dpr;
      const y = this.height - (p.y + p.height) * this.dpr;
      gl.viewport(Math.round(x), Math.round(y), Math.round(p.width * this.dpr), Math.round(p.height * this.dpr));
    }
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.viewport(0, 0, this.width, this.height);
  }

  /** Copies the scene under `region` to the snapshot and builds `levels` pyramid levels from it.
   * Returns the device px it touched. */
  private prepare(region: Box, scene: Target, snapshot: Target, levels: number, down: WebGLProgram): number {
    const gl = this.gl;
    const { height } = this;
    const y = height - region.y - region.h;
    gl.disable(gl.SCISSOR_TEST);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, scene.framebuffer);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, snapshot.framebuffer);
    gl.blitFramebuffer(
      region.x,
      y,
      region.x + region.w,
      y + region.h,
      region.x,
      y,
      region.x + region.w,
      y + region.h,
      gl.COLOR_BUFFER_BIT,
      gl.NEAREST,
    );
    gl.enable(gl.SCISSOR_TEST);
    let touched = region.w * region.h;
    gl.useProgram(down);
    gl.uniform1i(this.uniform(down, "u_src"), 0);
    gl.activeTexture(gl.TEXTURE0);
    let source = snapshot;
    for (let k = 1; k <= levels; k++) {
      const target = this.pyramid[k - 1]!;
      const scale = 2 ** k;
      // One texel of slack per level for the taps of the next level.
      const x0 = Math.max(0, Math.floor(region.x / scale) - 2);
      const y0 = Math.max(0, Math.floor(y / scale) - 2);
      const x1 = Math.min(target.width, Math.ceil((region.x + region.w) / scale) + 2);
      const y1 = Math.min(target.height, Math.ceil((y + region.h) / scale) + 2);
      gl.bindFramebuffer(gl.FRAMEBUFFER, target.framebuffer);
      gl.viewport(0, 0, target.width, target.height);
      gl.scissor(x0, y0, x1 - x0, y1 - y0);
      gl.bindTexture(gl.TEXTURE_2D, source.texture);
      gl.uniform2f(this.uniform(down, "u_texel"), 1 / source.width, 1 / source.height);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      touched += (x1 - x0) * (y1 - y0);
      source = target;
    }
    return touched;
  }

  private drawLayer(
    program: WebGLProgram,
    rect: Box,
    drawn: Box,
    look: GlassLook,
    snapshot: Target,
    levels: number,
  ): void {
    const gl = this.gl;
    const { width, height, dpr } = this;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.scene!.framebuffer);
    gl.viewport(0, 0, width, height);
    gl.scissor(drawn.x, height - drawn.y - drawn.h, drawn.w, drawn.h);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.useProgram(program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, snapshot.texture);
    for (let k = 1; k <= PYRAMID_LEVELS; k++) {
      gl.activeTexture(gl.TEXTURE0 + k);
      gl.bindTexture(gl.TEXTURE_2D, this.pyramid[k - 1]!.texture);
    }
    const u = (name: string) => this.uniform(program, name);
    gl.uniform2f(u("u_view"), width, height);
    gl.uniform4f(u("u_quad"), drawn.x, drawn.y, drawn.w, drawn.h);
    gl.uniform4f(u("u_rect"), rect.x, rect.y, rect.w, rect.h);
    // A radius that reaches half the short side is a pill or a circle: its ends stay circular.
    const corner = look.radius * 2 >= Math.min(rect.w, rect.h) / dpr ? 2 : look.corner;
    gl.uniform4f(u("u_shape"), look.radius * dpr, corner, look.bevel * dpr, look.thickness * dpr);
    gl.uniform4f(
      u("u_optics"),
      look.ior,
      Math.min(frostLevel(look.frost * dpr, PYRAMID_LEVELS), levels),
      look.saturation,
      look.dispersion,
    );
    gl.uniform4f(u("u_light"), look.specular, Math.cos(look.lightAngle), Math.sin(look.lightAngle), look.shadow);
    gl.uniform4f(u("u_tint"), look.tint[0], look.tint[1], look.tint[2], look.tint[3]);
    gl.uniform1f(u("u_opacity"), look.opacity);
    gl.uniform1f(u("u_shadowReach"), shadowReach(look) * dpr);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    gl.disable(gl.BLEND);
  }

  /** Frees the GL objects; the canvas stays. */
  dispose(): void {
    this.canvas.removeEventListener("webglcontextlost", this.onLost as EventListener);
    this.canvas.removeEventListener("webglcontextrestored", this.onRestored as EventListener);
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }
}
