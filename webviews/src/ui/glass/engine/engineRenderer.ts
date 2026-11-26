// The glass engine: the lens's renderer upgraded to a glass material (engineShader.ts has the
// optics). lens.ts keeps everything about the page (which rects are glass, what clips them, when to
// draw) and asks this module for three things it does not have:
//   - the prefilter: the wallpaper still blurred ONCE by the art's own blur (two separable passes
//     into a small mipmapped texture), so a frame reads one texel per glass pixel (plus five coarse ones for the veil), not nine;
//   - the pointer light: where the key light comes from, eased toward the pointer while it moves
//     near glass, settled (no frames) once it stops;
//   - the engine's per-frame uniforms (the ink, the veil, the index, the pointer).
//
// It is opt-in: the Debug choice Liquid Glass > Glass Engine (the host puts data-glass-engine on
// <html>), or the `glass-engine` experiment's `on` arm. Off (the default), lens.ts draws as before
// and nothing here runs. Reduce Motion and the cmux motion switch (data-cmux-motion other than full)
// hold the light still and drop the motion energy: the frame is the settled one.

import type { GlassShaderDialect } from "../glslDialect";
import { shaderSource } from "../glslDialect";
import { PREFILTER_FRAGMENT, PREFILTER_VERTEX } from "./engineShader";

/** The host's ask on `<html>` (WebTheme.swift, GlassLensMode.engine): draw with the engine. */
export const GLASS_ENGINE_ATTRIBUTE = "data-glass-engine";
/** On `<html>` while the engine draws (its still is up): glass.css's engine rules read it. */
export const GLASS_ENGINE_DRAWS_ATTRIBUTE = "data-glass-engine-draws";

/** The engine's uniforms beyond the lens's (lens.ts looks them up with its own). */
export const ENGINE_UNIFORMS = ["u_veil", "u_ink", "u_adapt", "u_ior", "u_pointer"] as const;

/** The glass's index of refraction: crown glass. */
export const ENGINE_IOR = 1.5;
/** How much of the theme surface the adaptive veil may add where the backdrop fights the text. */
export const ENGINE_ADAPT = 0.6;

type Target = { framebuffer: WebGLFramebuffer; texture: WebGLTexture; width: number; height: number };

/** The two-pass gaussian over the still. */
export class Prefilter {
  private readonly program: WebGLProgram;
  private readonly quad: WebGLBuffer;
  private readonly step: WebGLUniformLocation | null;
  private readonly lod: WebGLUniformLocation | null;
  private targets: [Target, Target] | null = null;
  /** Prefilter runs so far (tests and the bench read it). */
  runs = 0;

  private constructor(
    private readonly gl: WebGLRenderingContext,
    program: WebGLProgram,
    quad: WebGLBuffer,
    /** Plain WebGL1 reads no explicit level: its third argument is a bias over the automatic one,
     * which a target smaller than the source already raises to about the pass's level. */
    private readonly explicitLod: boolean,
  ) {
    this.program = program;
    this.quad = quad;
    this.step = gl.getUniformLocation(program, "u_step");
    this.lod = gl.getUniformLocation(program, "u_lod");
    gl.useProgram(program);
    gl.uniform1i(gl.getUniformLocation(program, "u_src"), 0);
  }

  static create(gl: WebGLRenderingContext, dialect: GlassShaderDialect): Prefilter | null {
    const vertex = compileShader(gl, gl.VERTEX_SHADER, shaderSource(PREFILTER_VERTEX, "vertex", dialect));
    const fragment = compileShader(gl, gl.FRAGMENT_SHADER, shaderSource(PREFILTER_FRAGMENT, "fragment", dialect));
    const program = gl.createProgram();
    const quad = gl.createBuffer();
    if (!vertex || !fragment || !program || !quad) return null;
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.bindAttribLocation(program, 0, "a_pos");
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1]), gl.STATIC_DRAW);
    return new Prefilter(gl, program, quad, dialect !== "webgl1");
  }

  /**
   * Blurs `source` (width x height, mipmapped) by `sigma` of its texels and returns the result with
   * its own mip chain, and its size. The passes run at the mip level where sigma is 2 to 4 texels, so
   * a wide blur costs as little as a narrow one. Under 0.6 texels it returns the source as is.
   * Leaves the caller's program, buffer and framebuffer state to the caller to restore.
   */
  run(
    source: WebGLTexture,
    width: number,
    height: number,
    sigma: number,
  ): { texture: WebGLTexture; size: [number, number] } {
    if (sigma < 0.6) return { texture: source, size: [width, height] };
    const gl = this.gl;
    const level = Math.max(0, Math.floor(Math.log2(sigma / 2)));
    const w = Math.max(1, width >> level);
    const h = Math.max(1, height >> level);
    const left = sigma / 2 ** level;
    const targets = this.targetsFor(w, h);
    if (!targets) return { texture: source, size: [width, height] };
    this.runs++;
    gl.useProgram(this.program);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.quad);
    // The engine's program keeps attributes 1-4 enabled with its own buffer: off for these draws.
    for (let index = 1; index < 5; index++) gl.disableVertexAttribArray(index);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 8, 0);
    gl.disable(gl.BLEND);
    gl.viewport(0, 0, w, h);
    gl.activeTexture(gl.TEXTURE0);
    // Seven bilinear taps a step apart cover about three sigma when the step is sigma / 2.4.
    const stride = left / 2.4;
    const passes: [WebGLTexture, Target, number, number, number][] = [
      [source, targets[0], stride / w, 0, this.explicitLod ? level : 0],
      [targets[0].texture, targets[1], 0, stride / h, 0],
    ];
    for (const [input, target, sx, sy, lod] of passes) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, target.framebuffer);
      gl.bindTexture(gl.TEXTURE_2D, input);
      gl.uniform2f(this.step, sx, sy);
      gl.uniform1f(this.lod, lod);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.bindTexture(gl.TEXTURE_2D, targets[1].texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.enable(gl.BLEND);
    return { texture: targets[1].texture, size: [w, h] };
  }

  private targetsFor(width: number, height: number): [Target, Target] | null {
    const current = this.targets;
    if (current && current[0].width === width && current[0].height === height) return current;
    this.release();
    const first = makeTarget(this.gl, width, height);
    const second = makeTarget(this.gl, width, height);
    if (!first || !second) return null;
    this.targets = [first, second];
    return this.targets;
  }

  release(): void {
    for (const target of this.targets ?? []) {
      this.gl.deleteFramebuffer(target.framebuffer);
      this.gl.deleteTexture(target.texture);
    }
    this.targets = null;
  }
}

function makeTarget(gl: WebGLRenderingContext, width: number, height: number): Target | null {
  const texture = gl.createTexture();
  const framebuffer = gl.createFramebuffer();
  if (!texture || !framebuffer) return null;
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
  const ok = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  if (ok) return { framebuffer, texture, width, height };
  gl.deleteFramebuffer(framebuffer);
  gl.deleteTexture(texture);
  return null;
}

function compileShader(gl: WebGLRenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS) && !gl.isContextLost()) {
    console.warn("cmux glass engine: shader", gl.getShaderInfoLog(shader));
    return null;
  }
  return shader;
}

/** The light eases this fraction of the way to the pointer each frame (about 90 ms to settle at 120 Hz). */
const EASE = 0.28;
/** Closer than this (CSS px) to its target, the light stops and draws no more frames. */
const SETTLED = 0.5;

/**
 * The key light's pointer: eased toward the last pointer position while it moves, its pull (z) up
 * while the pointer is over the page and down once it leaves. Listens only while attached.
 */
export class PointerLight {
  /** The eased pointer (CSS px) and its pull, 0 to 1: what u_pointer gets. */
  readonly value: [number, number, number] = [0, 0, 0];
  private target: [number, number, number] = [0, 0, 0];
  private doc: Document | null = null;

  constructor(private readonly onMove: () => void) {}

  attach(doc: Document): void {
    if (this.doc) return;
    this.doc = doc;
    doc.addEventListener("pointermove", this.onPointer, { passive: true });
    doc.documentElement.addEventListener("pointerleave", this.onLeave, { passive: true });
  }

  detach(): void {
    this.doc?.removeEventListener("pointermove", this.onPointer);
    this.doc?.documentElement.removeEventListener("pointerleave", this.onLeave);
    this.doc = null;
    this.value[2] = 0;
    this.target[2] = 0;
  }

  /** One frame of easing; true while the light still moves (the lens draws another frame). */
  step(): boolean {
    const value = this.value;
    const target = this.target;
    const dx = target[0] - value[0];
    const dy = target[1] - value[1];
    const dz = target[2] - value[2];
    if (Math.abs(dx) < SETTLED && Math.abs(dy) < SETTLED && Math.abs(dz) < 0.01) {
      value[0] = target[0];
      value[1] = target[1];
      value[2] = target[2];
      return false;
    }
    value[0] += dx * EASE;
    value[1] += dy * EASE;
    value[2] += dz * EASE;
    return true;
  }

  private readonly onPointer = (event: PointerEvent) => {
    // The first move jumps there: the light comes up where the pointer is, not from the corner.
    if (this.target[2] === 0) {
      this.value[0] = event.clientX;
      this.value[1] = event.clientY;
    }
    this.target = [event.clientX, event.clientY, 1];
    this.onMove();
  };

  private readonly onLeave = () => {
    this.target[2] = 0;
    this.onMove();
  };
}

/** Whether the page holds motion still: Reduce Motion, or the cmux motion switch off or reduced. */
export function motionHeld(root: HTMLElement, view: Window): boolean {
  const policy = root.getAttribute("data-cmux-motion");
  if (policy === "off" || policy === "reduced") return true;
  return typeof view.matchMedia === "function" && view.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** How fast a glass moved this frame (CSS px) as motion energy: a jump up, then 15% less a frame. */
export function nextEnergy(previous: number, moved: number): number {
  return Math.max(previous * 0.85, Math.min(1, moved / 40));
}
