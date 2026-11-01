// The liquid glass lens (plans/cmux-next/glass-lens-DESIGN.md, "The lens"). WebKit renders nothing
// for `backdrop-filter: url(#svg)`, and the wallpaper is drawn natively behind the transparent web
// view, so the page has no pixels to bend. The host sends a still of the art as drawn
// (`cmuxTheme.backdrop`), and this module draws it once more, on one WebGL canvas behind all content
// (--layer-backdrop), composited under the same native tint and page color: outside the glass the
// copy equals what is under the page, and inside each `.ui-glass` rounded rect it is bent inward at
// the rim, frosted, (Spectrum) split per channel, lit along the rim (--glass-gloss) and, if a surface
// asks, zoomed a little at the center (--glass-magnify).
//
// Cost: nothing at all (no canvas, no listeners but the mode and backdrop watchers) under plain
// glass, Reduce Transparency, with no still, or with no glass in the document. Otherwise a
// requestAnimationFrame loop runs only after a scroll, resize, DOM change, transition or animation,
// reads every rect in one pass (no layout writes), draws only when a rect changed, and stops after
// STABLE_FRAMES unchanged frames.
import { parseComputedColor, type RGBA } from "../../backdrop";
import {
  BACKDROP_EVENT,
  GLASS_ATTRIBUTE,
  GLASS_CLASS,
  LENS_ATTRIBUTE,
  LIVE_BACKGROUND_ATTRIBUTE,
  NATIVE_GLASS_ATTRIBUTE,
  installBackdropFallback,
  powerOfTwo,
  readBackdrop,
  resolveGlassMode,
  type BackdropState,
  type GlassMode,
} from "./glassState";

/** The most glass surfaces drawn at once; more on screen draw as plain CSS glass. */
const MAX_RECTS = 32;
/** How far past each glass the copy continues and fades out, CSS px. */
const MARGIN = 48;
/** How far a joined edge (--glass-join) carries the shape past the box, CSS px: past any rim band,
 * so the joined side has no bend; the glass itself is still clipped to the box. */
const JOIN_REACH = 240;
/** Unchanged frames before the loop stops. */
const STABLE_FRAMES = 20;
/** Floats per vertex: position 2, rect 4, clip 4, shape 4 (radius, refraction, blur, dispersion),
 * extra 4 (opacity, gloss, magnify, unused). */
const FLOATS = 18;
const VERTICES = 6;
const MAX_TEXTURE = 1024;
const REDUCE_TRANSPARENCY = "(prefers-reduced-transparency: reduce)";

type Surface = {
  radius: number;
  /** The radius was a percentage of the box (`border-radius: 50%`), as a fraction. */
  radiusFraction: number;
  /** --glass-join: the top or bottom edge continues into a neighbouring glass. */
  joinTop: boolean;
  joinBottom: boolean;
  refraction: number;
  blur: number;
  dispersion: number;
  /** --glass-gloss: the specular light the rim catches, 0 to 1 (none: 0). */
  gloss: number;
  /** --glass-magnify: how much the center zooms the wallpaper, 0 to 0.2 (none: 0). */
  magnify: number;
  opacity: number;
  visible: boolean;
  /** Ancestors that clip it (overflow other than visible), nearest first. */
  clippers: Element[];
  stale: boolean;
};

type Program = {
  gl: WebGLRenderingContext | WebGL2RenderingContext;
  program: WebGLProgram;
  buffer: WebGLBuffer;
  texture: WebGLTexture;
  uniforms: Record<string, WebGLUniformLocation | null>;
};

const VERTEX = `
ATTR vec2 a_pos;
ATTR vec4 a_rect;
ATTR vec4 a_clip;
ATTR vec4 a_shape;
ATTR vec4 a_extra;
uniform vec2 u_view;
VARY vec2 v_p;
VARY vec4 v_rect;
VARY vec4 v_clip;
VARY vec4 v_shape;
VARY vec4 v_extra;
void main() {
  v_p = a_pos;
  v_rect = a_rect;
  v_clip = a_clip;
  v_shape = a_shape;
  v_extra = a_extra;
  vec2 ndc = a_pos / u_view * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}`;

// Kept in step with glassState.ts (roundedRectSdf, rimBand, lensProfile, channelStrengths).
const FRAGMENT = `
uniform sampler2D u_tex;
uniform vec4 u_art;
uniform vec2 u_texSize;
uniform float u_artBlur;
uniform vec4 u_tint;
uniform vec4 u_surface;
uniform float u_pass;
uniform float u_margin;
uniform float u_dpr;
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

// A gaussian-like blur of sigma CSS px: the mip level about a quarter of sigma, then a center and
// two rings of taps, so it reads smooth with no blocky mips.
vec3 frosted(vec2 p, float sigma) {
  float texels = sigma * u_texSize.x / u_art.z;
  if (texels < 0.6) return tap(p, 0.0);
  float lod = max(0.0, log2(texels) - 1.5);
  vec3 sum = tap(p, lod) * 0.16;
  float a = sigma * 0.7;
  float b = sigma * 1.6;
  sum += (tap(p + vec2(a, 0.0), lod) + tap(p - vec2(a, 0.0), lod) + tap(p + vec2(0.0, a), lod) + tap(p - vec2(0.0, a), lod)) * 0.13;
  vec2 d = vec2(b, b) * 0.7071;
  sum += (tap(p + d, lod) + tap(p - d, lod) + tap(p + vec2(d.x, -d.y), lod) + tap(p - vec2(d.x, -d.y), lod)) * 0.08;
  return sum;
}

void main() {
  vec2 halfSize = v_rect.zw * 0.5;
  vec2 lp = v_p - (v_rect.xy + halfSize);
  float minHalf = min(halfSize.x, halfSize.y);
  float r = min(v_shape.x, minHalf);
  float sd = sdRound(lp, halfSize, r);
  bool inClip = v_p.x >= v_clip.x && v_p.y >= v_clip.y && v_p.x < v_clip.z && v_p.y < v_clip.w;
  vec3 color;
  float alpha;
  if (u_pass < 0.5) {
    // The copy around the glass, fading out: what is already under the page.
    if (inClip && sd < 0.0) discard;
    alpha = 1.0 - smoothstep(0.0, u_margin, max(sd, 0.0));
    if (alpha <= 0.0) discard;
    color = frosted(v_p, u_artBlur);
  } else {
    if (!inClip || sd >= 0.0) discard;
    alpha = clamp(-sd * u_dpr, 0.0, 1.0) * v_extra.x;
    float refraction = v_shape.y;
    float band = min(minHalf, max(refraction * 3.0, 8.0));
    float t = clamp(-sd / band, 0.0, 1.0);
    float bend = refraction * (1.0 - sqrt(max(0.0, t * (2.0 - t))));
    // The edge normal of the same box with a corner no smaller than the band: smooth everywhere
    // the bend reaches, with no seam along the diagonals.
    float rn = min(max(r, band), minHalf);
    vec2 q = abs(lp) - (halfSize - rn);
    vec2 n = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    n *= vec2(lp.x < 0.0 ? -1.0 : 1.0, lp.y < 0.0 ? -1.0 : 1.0);
    float sigma = sqrt(u_artBlur * u_artBlur + v_shape.z * v_shape.z);
    float d = v_shape.w;
    // Magnify: the center reads the wallpaper a little closer, as a thick lens does.
    vec2 base = v_p - lp * v_extra.z;
    vec2 at = base - n * bend;
    if (d > 0.0) {
      color = vec3(
        frosted(at, sigma).r,
        frosted(base - n * bend * (1.0 + d), sigma).g,
        frosted(base - n * bend * (1.0 + 2.0 * d), sigma).b);
    } else {
      color = frosted(at, sigma);
    }
    color = mix(color, u_tint.rgb, u_tint.a);
    color = mix(color, u_surface.rgb, u_surface.a);
    // Gloss: the rim facing the light (above, a little left) catches a bright line that thins
    // away round the corners, the opposite rim a fainter one, as light through a thick edge.
    // No texture taps: a few ALU ops per rim pixel.
    float gloss = v_extra.y;
    if (gloss > 0.0) {
      float facing = dot(n, normalize(vec2(-0.42, -1.0)));
      float rim = 1.0 - smoothstep(0.0, max(1.5, min(band * 0.4, 7.0)), -sd);
      float light = pow(max(facing, 0.0), 2.0) + 0.4 * pow(max(-facing, 0.0), 3.0);
      color += vec3(rim * light * gloss * 0.6);
    }
    OUT_COLOR = vec4(min(color, vec3(1.0)) * alpha, alpha);
    return;
  }
  color = mix(color, u_tint.rgb, u_tint.a);
  color = mix(color, u_surface.rgb, u_surface.a);
  OUT_COLOR = vec4(color * alpha, alpha);
}`;

/** How the fragment shader reads a mip level: WebGL2's textureLod, WebGL1's EXT_shader_texture_lod,
 * or plain WebGL1, which has no explicit level in a fragment shader (a bias over the automatic one). */
export type GlassShaderDialect = "webgl2" | "webgl1-lod" | "webgl1";

function shaderSource(source: string, kind: "vertex" | "fragment", dialect: GlassShaderDialect): string {
  if (dialect === "webgl2")
    return (
      "#version 300 es\nprecision highp float;\n" +
      source
        .replaceAll("ATTR ", "in ")
        .replaceAll("VARY ", kind === "vertex" ? "out " : "in ")
        .replace("OUT_DECL", "out vec4 cmuxColor;")
        .replaceAll("OUT_COLOR", "cmuxColor")
        .replaceAll("SAMPLE(", "textureLod(")
    );
  const lod = dialect === "webgl1-lod" && kind === "fragment";
  return (
    (lod ? "#extension GL_EXT_shader_texture_lod : enable\n" : "") +
    "precision highp float;\n" +
    source
      .replaceAll("ATTR ", "attribute ")
      .replaceAll("VARY ", "varying ")
      .replace("OUT_DECL", "")
      .replaceAll("OUT_COLOR", "gl_FragColor")
      .replaceAll("SAMPLE(", lod ? "texture2DLodEXT(" : "texture2D(")
  );
}

/** Both shaders in a dialect, for tests that compile every dialect a browser can take. */
export function glassShaderSources(dialect: GlassShaderDialect): { vertex: string; fragment: string } {
  return { vertex: shaderSource(VERTEX, "vertex", dialect), fragment: shaderSource(FRAGMENT, "fragment", dialect) };
}

function compile(gl: WebGLRenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS) && !gl.isContextLost()) {
    console.warn("cmux glass lens: shader", gl.getShaderInfoLog(shader));
    return null;
  }
  return shader;
}

function createProgram(canvas: HTMLCanvasElement): Program | null {
  const options: WebGLContextAttributes = {
    alpha: true,
    premultipliedAlpha: true,
    antialias: false,
    depth: false,
    stencil: false,
    preserveDrawingBuffer: false,
    powerPreference: "low-power",
  };
  const gl2 = canvas.getContext("webgl2", options);
  const gl = gl2 ?? canvas.getContext("webgl", options);
  if (!gl) return null;
  const dialect: GlassShaderDialect = gl2
    ? "webgl2"
    : gl.getExtension("EXT_shader_texture_lod")
      ? "webgl1-lod"
      : "webgl1";
  const vertex = compile(gl, gl.VERTEX_SHADER, shaderSource(VERTEX, "vertex", dialect));
  const fragment = compile(gl, gl.FRAGMENT_SHADER, shaderSource(FRAGMENT, "fragment", dialect));
  const program = gl.createProgram();
  if (!vertex || !fragment || !program) return null;
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  const attributes = ["a_pos", "a_rect", "a_clip", "a_shape", "a_extra"];
  attributes.forEach((name, index) => gl.bindAttribLocation(program, index, name));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    console.warn("cmux glass lens: link", gl.getProgramInfoLog(program));
    return null;
  }
  gl.useProgram(program);
  const buffer = gl.createBuffer();
  const texture = gl.createTexture();
  if (!buffer || !texture) return null;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, MAX_RECTS * VERTICES * FLOATS * 4, gl.DYNAMIC_DRAW);
  const sizes = [2, 4, 4, 4, 4];
  let offset = 0;
  sizes.forEach((size, index) => {
    gl.enableVertexAttribArray(index);
    gl.vertexAttribPointer(index, size, gl.FLOAT, false, FLOATS * 4, offset * 4);
    offset += size;
  });
  const uniforms: Program["uniforms"] = {};
  for (const name of [
    "u_view",
    "u_tex",
    "u_art",
    "u_texSize",
    "u_artBlur",
    "u_tint",
    "u_surface",
    "u_pass",
    "u_margin",
    "u_dpr",
  ])
    uniforms[name] = gl.getUniformLocation(program, name);
  gl.uniform1i(uniforms.u_tex!, 0);
  gl.uniform1f(uniforms.u_margin!, MARGIN);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  return { gl, program, buffer, texture, uniforms };
}

function px(value: string, fallback: number): number {
  const number = Number.parseFloat(value);
  return Number.isFinite(number) ? number : fallback;
}

/** The product of the element's and its ancestors' opacity. */
function effectiveOpacity(element: Element, view: Window): number {
  let opacity = 1;
  for (let node: Element | null = element; node && opacity > 0; node = node.parentElement)
    opacity *= px(view.getComputedStyle(node).opacity, 1);
  return opacity;
}

/** One document's lens. */
class GlassLens {
  private readonly view: Window;
  private readonly root: HTMLElement;
  private readonly glass: HTMLCollectionOf<Element>;
  private readonly reduceQuery: MediaQueryList | null;
  private mode: GlassMode = "plain";
  private backdrop: BackdropState;
  /** WebGL failed once in this document: CSS glass only from then on. */
  private capable = true;
  private armed = false;
  private running = false;

  private canvas: HTMLCanvasElement | null = null;
  private gpu: Program | null = null;
  private image: HTMLImageElement | null = null;
  private imageKey: string | null = null;
  private textureReady = false;
  private textureSize: [number, number] = [1, 1];

  private surfaces = new WeakMap<Element, Surface>();
  private readonly observed = new Set<Element>();
  private resizeObserver: ResizeObserver | null = null;
  private readonly mutations: MutationObserver;
  private readonly rootWatch: MutationObserver;

  private width = 0;
  private height = 0;
  private dpr = 1;
  private frame = 0;
  private stable = 0;
  private hot = false;
  private needsDraw = true;
  private current = new Float32Array(MAX_RECTS * VERTICES * FLOATS);
  private next = new Float32Array(MAX_RECTS * VERTICES * FLOATS);
  private currentCount = -1;
  private readonly clip = new Float64Array(4);
  private tint: RGBA = { r: 0, g: 0, b: 0, a: 0 };
  private surface: RGBA = { r: 0, g: 0, b: 0, a: 0 };

  /** Draws so far (tests read it through glassLensState). */
  draws = 0;
  rects = 0;

  constructor(private readonly doc: Document) {
    this.view = doc.defaultView!;
    this.root = doc.documentElement;
    this.glass = doc.getElementsByClassName(GLASS_CLASS);
    this.backdrop = readBackdrop(this.view);
    this.reduceQuery = typeof this.view.matchMedia === "function" ? this.view.matchMedia(REDUCE_TRANSPARENCY) : null;
    this.reduceQuery?.addEventListener("change", this.reconcile);
    this.view.addEventListener(BACKDROP_EVENT, this.onBackdrop);
    this.view.addEventListener("cmux-theme", this.onTheme);
    this.rootWatch = new MutationObserver(this.reconcile);
    this.rootWatch.observe(this.root, {
      attributes: true,
      attributeFilter: [GLASS_ATTRIBUTE, NATIVE_GLASS_ATTRIBUTE, LIVE_BACKGROUND_ATTRIBUTE, "data-reduce-transparency"],
    });
    this.mutations = new MutationObserver(this.onMutations);
    this.reconcile();
  }

  state() {
    return {
      mode: this.mode,
      armed: this.armed,
      running: this.running,
      drawing: this.drawing(),
      draws: this.draws,
      rects: this.rects,
    };
  }

  private drawing(): boolean {
    return this.running && this.textureReady && this.gpu !== null;
  }

  private readonly reconcile = () => {
    this.mode = resolveGlassMode(
      this.root.getAttribute(GLASS_ATTRIBUTE),
      this.root.hasAttribute("data-reduce-transparency") || this.reduceQuery?.matches === true,
    );
    // A host that draws its own glass under the page (NATIVE_GLASS_ATTRIBUTE) gets no lens over it.
    const want =
      this.capable &&
      this.mode !== "plain" &&
      !this.root.hasAttribute(NATIVE_GLASS_ATTRIBUTE) &&
      // A live background (ui/liveBackground) is drawn in the page: the host's still would cover it.
      !this.root.hasAttribute(LIVE_BACKGROUND_ATTRIBUTE) &&
      this.backdrop.image !== null &&
      this.backdrop.rect !== null;
    if (want !== this.armed) {
      this.armed = want;
      // `style` too: an inline move (a virtualized row, a drag) changes no class and fires no scroll.
      if (want)
        this.mutations.observe(this.root, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ["class", "style"],
        });
      else this.mutations.disconnect();
    }
    if (!want) {
      this.stop();
      this.image = null;
      this.imageKey = null;
      return;
    }
    // No glass on the page: don't even decode the still.
    if (this.glass.length > 0) {
      this.loadImage();
      this.start();
    } else this.stop();
    // Spectrum on or off changes each surface's dispersion.
    this.markAllStale();
    this.invalidate();
  };

  private readonly onBackdrop = () => {
    this.backdrop = readBackdrop(this.view);
    if (this.running) this.readColors();
    this.needsDraw = true;
    this.reconcile();
  };

  private readonly onTheme = () => {
    if (!this.running) return;
    this.readColors();
    this.markAllStale();
    this.invalidate();
  };

  private readonly onMutations = (records: MutationRecord[]) => {
    if (!this.running) {
      if (this.glass.length > 0) this.reconcile();
      return;
    }
    if (this.glass.length === 0) {
      this.stop();
      return;
    }
    for (const record of records) {
      // A sibling came or went: a glass beside it may join it or stop (--glass-join reads :has()).
      if (record.type === "childList") {
        const children = (record.target as Partial<ParentNode>).children;
        for (let index = 0; children && index < children.length; index++) {
          const child = children[index]!;
          if (child.classList.contains(GLASS_CLASS)) this.markStale(child);
        }
        continue;
      }
      if (record.type !== "attributes" || record.attributeName !== "class") continue;
      const target = record.target as Element;
      if (target.classList.contains(GLASS_CLASS)) this.markStale(target);
      // An ancestor's class can change what clips or fades its glass.
      else if (target.getElementsByClassName(GLASS_CLASS).length > 0) this.markAllStale();
    }
    this.invalidate();
  };

  private readonly onScroll = () => this.invalidate();
  private readonly onMotion = () => {
    this.hot = true;
    this.invalidate();
  };
  private readonly onResize = () => {
    this.resize();
    this.invalidate();
  };
  private readonly onContextLost = (event: Event) => {
    // A canvas stop() dropped can report its loss after a new one started: not ours any more.
    if (event.target !== this.canvas) return;
    event.preventDefault();
    this.gpu = null;
    this.textureReady = false;
    this.root.removeAttribute(LENS_ATTRIBUTE);
  };
  private readonly onContextRestored = () => {
    if (!this.canvas) return;
    this.gpu = createProgram(this.canvas);
    this.uploadTexture();
    this.invalidate();
  };

  private start(): void {
    if (this.running) return;
    const canvas = this.doc.createElement("canvas");
    canvas.setAttribute("aria-hidden", "true");
    canvas.dataset.cmuxGlassLens = "";
    canvas.style.cssText =
      "position:fixed;inset:0;width:100%;height:100%;z-index:var(--layer-backdrop, -1);pointer-events:none;contain:strict;";
    const gpu = createProgram(canvas);
    if (!gpu) {
      this.capable = false;
      this.reconcile();
      return;
    }
    this.canvas = canvas;
    this.gpu = gpu;
    canvas.addEventListener("webglcontextlost", this.onContextLost);
    canvas.addEventListener("webglcontextrestored", this.onContextRestored);
    this.root.append(canvas);
    this.running = true;
    this.surfaces = new WeakMap();
    this.resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) this.markStale(entry.target);
      this.invalidate();
    });
    this.doc.addEventListener("scroll", this.onScroll, { capture: true, passive: true });
    this.view.addEventListener("resize", this.onResize);
    this.doc.addEventListener("transitionrun", this.onMotion, { capture: true, passive: true });
    this.doc.addEventListener("animationstart", this.onMotion, { capture: true, passive: true });
    this.readColors();
    this.resize();
    this.uploadTexture();
  }

  private stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.frame) this.view.cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.doc.removeEventListener("scroll", this.onScroll, { capture: true });
    this.view.removeEventListener("resize", this.onResize);
    this.doc.removeEventListener("transitionrun", this.onMotion, { capture: true });
    this.doc.removeEventListener("animationstart", this.onMotion, { capture: true });
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.observed.clear();
    this.canvas?.removeEventListener("webglcontextlost", this.onContextLost);
    this.canvas?.removeEventListener("webglcontextrestored", this.onContextRestored);
    this.gpu?.gl.getExtension("WEBGL_lose_context")?.loseContext();
    this.gpu = null;
    this.textureReady = false;
    this.canvas?.remove();
    this.canvas = null;
    this.currentCount = -1;
    this.root.removeAttribute(LENS_ATTRIBUTE);
  }

  private loadImage(): void {
    const { image, key } = this.backdrop;
    const id = key ?? image;
    if (!image || id === this.imageKey) return;
    this.imageKey = id;
    this.textureReady = false;
    const element = new Image();
    element.decoding = "async";
    element.src = image;
    const done = () => {
      if (this.imageKey !== id) return;
      this.image = element;
      this.uploadTexture();
      this.invalidate();
    };
    element.decode().then(done, () => {
      // A still that fails to decode draws nothing: CSS glass until the next one.
      if (this.imageKey === id) this.image = null;
    });
  }

  /** The still, redrawn at power-of-two size (mipmaps in WebGL1), uploaded with its mip chain. */
  private uploadTexture(): void {
    const gpu = this.gpu;
    const image = this.image;
    if (!gpu || !image || !image.naturalWidth) return;
    const width = powerOfTwo(Math.min(image.naturalWidth, MAX_TEXTURE), MAX_TEXTURE);
    const height = powerOfTwo(Math.min(image.naturalHeight, MAX_TEXTURE), MAX_TEXTURE);
    const scratch = this.doc.createElement("canvas");
    scratch.width = width;
    scratch.height = height;
    const context = scratch.getContext("2d");
    if (!context) return;
    context.imageSmoothingQuality = "high";
    context.drawImage(image, 0, 0, width, height);
    const { gl } = gpu;
    gl.bindTexture(gl.TEXTURE_2D, gpu.texture);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, scratch);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.generateMipmap(gl.TEXTURE_2D);
    scratch.width = 0;
    this.textureSize = [width, height];
    this.textureReady = true;
    this.needsDraw = true;
    this.root.setAttribute(LENS_ATTRIBUTE, "");
  }

  /** The native tint and the page color, resolved to sRGB through one probe. */
  private readColors(): void {
    const probe = this.doc.createElement("span");
    probe.style.cssText = "position:absolute;width:0;height:0;visibility:hidden;pointer-events:none";
    this.root.append(probe);
    const read = (color: string): RGBA => {
      probe.style.backgroundColor = "";
      probe.style.backgroundColor = color;
      return parseComputedColor(this.view.getComputedStyle(probe).backgroundColor) ?? { r: 0, g: 0, b: 0, a: 0 };
    };
    this.tint = read(this.backdrop.tint || "transparent");
    this.surface = read("var(--cmux-surface-background, transparent)");
    probe.remove();
    this.needsDraw = true;
  }

  private resize(): void {
    if (!this.canvas) return;
    this.width = this.root.clientWidth || this.view.innerWidth;
    this.height = this.root.clientHeight || this.view.innerHeight;
    this.dpr = Math.min(2, Math.max(1, this.view.devicePixelRatio || 1));
    const width = Math.max(1, Math.round(this.width * this.dpr));
    const height = Math.max(1, Math.round(this.height * this.dpr));
    if (this.canvas.width !== width) this.canvas.width = width;
    if (this.canvas.height !== height) this.canvas.height = height;
    this.needsDraw = true;
  }

  private markStale(element: Element): void {
    const surface = this.surfaces.get(element);
    if (surface) surface.stale = true;
  }

  private markAllStale(): void {
    this.surfaces = new WeakMap();
  }

  private invalidate(): void {
    this.stable = 0;
    if (this.running && !this.frame) this.frame = this.view.requestAnimationFrame(this.tick);
  }

  private refresh(element: Element, previous: Surface | undefined): Surface {
    const style = this.view.getComputedStyle(element);
    const join = style.getPropertyValue("--glass-join").trim();
    const joinTop = join === "top" || join === "both";
    const joinBottom = join === "bottom" || join === "both";
    // A joined edge's corners are square: the radius is the free edge's (both joined: none).
    const radius = joinTop && joinBottom ? "0px" : joinTop ? style.borderBottomLeftRadius : style.borderTopLeftRadius;
    const surface: Surface = previous ?? {
      radius: 0,
      radiusFraction: 0,
      joinTop: false,
      joinBottom: false,
      refraction: 0,
      blur: 0,
      dispersion: 0,
      gloss: 0,
      magnify: 0,
      opacity: 1,
      visible: true,
      clippers: [],
      stale: false,
    };
    surface.joinTop = joinTop;
    surface.joinBottom = joinBottom;
    surface.radiusFraction = radius.endsWith("%") ? px(radius, 0) / 100 : 0;
    surface.radius = surface.radiusFraction ? 0 : px(radius, 0);
    surface.refraction = Math.max(0, px(style.getPropertyValue("--glass-refraction"), 14));
    surface.blur = Math.max(0, px(style.getPropertyValue("--glass-blur"), 6));
    surface.dispersion =
      this.mode === "spectrum" ? Math.max(0, px(style.getPropertyValue("--glass-dispersion"), 0)) : 0;
    surface.gloss = Math.min(1, Math.max(0, px(style.getPropertyValue("--glass-gloss"), 0)));
    surface.magnify = Math.min(0.2, Math.max(0, px(style.getPropertyValue("--glass-magnify"), 0)));
    surface.visible = style.visibility !== "hidden" && style.display !== "none";
    surface.clippers.length = 0;
    let fixed = style.position === "fixed";
    for (let node = element.parentElement; node && !fixed; node = node.parentElement) {
      if (node === this.doc.body || node === this.root) break;
      const ancestor = this.view.getComputedStyle(node);
      if (ancestor.overflowX !== "visible" || ancestor.overflowY !== "visible") surface.clippers.push(node);
      // A fixed box escapes the overflow of everything above it.
      fixed = ancestor.position === "fixed";
    }
    surface.opacity = effectiveOpacity(element, this.view);
    surface.stale = false;
    this.surfaces.set(element, surface);
    if (!this.observed.has(element)) {
      this.observed.add(element);
      this.resizeObserver?.observe(element);
    }
    return surface;
  }

  /** Every visible glass's rect, clip and shape into `next`, in one read pass; returns the count. */
  private measure(): number {
    const out = this.next;
    const clip = this.clip;
    const width = this.width;
    const height = this.height;
    let count = 0;
    for (let index = 0; index < this.glass.length && count < MAX_RECTS; index++) {
      const element = this.glass[index]!;
      let surface = this.surfaces.get(element);
      if (!surface || surface.stale) surface = this.refresh(element, surface);
      else if (this.hot) surface.opacity = effectiveOpacity(element, this.view);
      if (!surface.visible || surface.opacity <= 0.002) continue;
      const box = element.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) continue;
      if (box.right + MARGIN < 0 || box.bottom + MARGIN < 0 || box.left - MARGIN > width || box.top - MARGIN > height)
        continue;
      clip[0] = 0;
      clip[1] = 0;
      clip[2] = width;
      clip[3] = height;
      let open = true;
      for (let c = 0; c < surface.clippers.length && open; c++) {
        const bounds = surface.clippers[c]!.getBoundingClientRect();
        clip[0] = Math.max(clip[0]!, bounds.left);
        clip[1] = Math.max(clip[1]!, bounds.top);
        clip[2] = Math.min(clip[2]!, bounds.right);
        clip[3] = Math.min(clip[3]!, bounds.bottom);
        open = clip[2]! > clip[0]! && clip[3]! > clip[1]!;
      }
      // A joined edge: the shape runs on past it (no rim bend there) and the glass is clipped to it.
      let shapeTop = box.top;
      let shapeBottom = box.bottom;
      if (surface.joinTop) {
        shapeTop -= JOIN_REACH;
        clip[1] = Math.max(clip[1]!, box.top);
      }
      if (surface.joinBottom) {
        shapeBottom += JOIN_REACH;
        clip[3] = Math.min(clip[3]!, box.bottom);
      }
      open = open && clip[3]! > clip[1]!;
      if (!open) continue;
      const radius = surface.radiusFraction ? surface.radiusFraction * Math.min(box.width, box.height) : surface.radius;
      const x0 = Math.max(0, box.left - MARGIN);
      const y0 = Math.max(0, shapeTop - MARGIN);
      const x1 = Math.min(width, box.right + MARGIN);
      const y1 = Math.min(height, shapeBottom + MARGIN);
      let at = count * VERTICES * FLOATS;
      for (let corner = 0; corner < VERTICES; corner++) {
        // Two triangles: (0,0) (1,0) (0,1), (0,1) (1,0) (1,1).
        const right = corner === 1 || corner === 4 || corner === 5;
        const bottom = corner === 2 || corner === 3 || corner === 5;
        out[at++] = right ? x1 : x0;
        out[at++] = bottom ? y1 : y0;
        out[at++] = box.left;
        out[at++] = shapeTop;
        out[at++] = box.width;
        out[at++] = shapeBottom - shapeTop;
        out[at++] = clip[0]!;
        out[at++] = clip[1]!;
        out[at++] = clip[2]!;
        out[at++] = clip[3]!;
        out[at++] = radius;
        out[at++] = surface.refraction;
        out[at++] = surface.blur;
        out[at++] = surface.dispersion;
        out[at++] = Math.min(1, surface.opacity);
        out[at++] = surface.gloss;
        out[at++] = surface.magnify;
        out[at++] = 0;
      }
      count++;
    }
    return count;
  }

  private readonly tick = () => {
    this.frame = 0;
    if (!this.running) return;
    const count = this.measure();
    let changed = count !== this.currentCount;
    if (!changed) {
      const end = count * VERTICES * FLOATS;
      for (let index = 0; index < end; index++) {
        if (this.next[index] !== this.current[index]) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      const swap = this.current;
      this.current = this.next;
      this.next = swap;
      this.currentCount = count;
    }
    if ((changed || this.needsDraw) && this.drawing()) {
      this.draw();
      this.stable = 0;
    } else if (++this.stable >= STABLE_FRAMES) {
      this.hot = false;
      this.prune();
      return;
    }
    this.frame = this.view.requestAnimationFrame(this.tick);
  };

  /** Stops observing glass that left the document. */
  private prune(): void {
    for (const element of this.observed) {
      if (element.isConnected) continue;
      this.observed.delete(element);
      this.resizeObserver?.unobserve(element);
    }
  }

  private draw(): void {
    const gpu = this.gpu!;
    const { gl, uniforms } = gpu;
    const art = this.backdrop.rect!;
    this.needsDraw = false;
    this.draws++;
    this.rects = this.currentCount;
    gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (this.currentCount <= 0) return;
    gl.bindBuffer(gl.ARRAY_BUFFER, gpu.buffer);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, this.current);
    gl.uniform2f(uniforms.u_view!, this.width, this.height);
    gl.uniform4f(uniforms.u_art!, art.x, art.y, art.width, art.height);
    gl.uniform2f(uniforms.u_texSize!, this.textureSize[0], this.textureSize[1]);
    gl.uniform1f(uniforms.u_artBlur!, this.backdrop.blur);
    gl.uniform4f(uniforms.u_tint!, this.tint.r / 255, this.tint.g / 255, this.tint.b / 255, this.tint.a);
    gl.uniform4f(uniforms.u_surface!, this.surface.r / 255, this.surface.g / 255, this.surface.b / 255, this.surface.a);
    gl.uniform1f(uniforms.u_dpr!, this.dpr);
    const vertices = this.currentCount * VERTICES;
    // The copy around every glass first, then every lens over it, so no margin covers a lens.
    gl.uniform1f(uniforms.u_pass!, 0);
    gl.drawArrays(gl.TRIANGLES, 0, vertices);
    gl.uniform1f(uniforms.u_pass!, 1);
    gl.drawArrays(gl.TRIANGLES, 0, vertices);
  }
}

const lenses = new WeakMap<Document, GlassLens>();

/** Starts the document's lens once (desktop.ts calls it for every first-party page and the agent
 * pane). Also defines the `cmuxTheme.backdrop` fallback when no host bootstrap did. */
export function installGlassLens(doc: Document = document): void {
  const view = doc.defaultView;
  if (!view || lenses.has(doc)) return;
  installBackdropFallback(view);
  // A DOM without observers (a unit test's light DOM) has nothing to lens: CSS glass only.
  if (typeof MutationObserver !== "function" || typeof ResizeObserver !== "function") return;
  lenses.set(doc, new GlassLens(doc));
}

/** The lens's state, for tests and debugging. */
export function glassLensState(doc: Document = document) {
  return lenses.get(doc)?.state() ?? null;
}
