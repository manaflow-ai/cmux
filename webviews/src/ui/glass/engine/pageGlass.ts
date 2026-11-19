// The glass engine in a page (design/glass.md, "Glass engine"): one canvas behind the content that
// draws every registered surface's glass over the host's still of the wallpaper (the one the lens
// reads, `cmuxTheme.backdrop`). A surface registers itself (useGlassEngine), so nothing walks the
// DOM: the driver reads only the registered boxes.
//
// Cost: nothing (no canvas, no listeners but the backdrop watcher) with no surface registered, no
// still, or Reduce Transparency. Otherwise a requestAnimationFrame loop runs only after a scroll,
// resize, a surface's size change, transition or animation, reads the registered rects in one pass
// (no layout writes), draws only when one changed, and stops after STABLE_FRAMES unchanged frames.
import { BACKDROP_EVENT, readBackdrop, type BackdropState } from "../glassState";
import { GlassEngine, type GlassLayer } from "./glassEngine";
import type { GlassLook } from "./optics";

/** On a surface while the engine draws its glass: its own CSS glass stands down (glass.css). */
export const GLASS_ENGINE_ATTRIBUTE = "data-glass-engine";
/** Unchanged frames before the loop stops. */
const STABLE_FRAMES = 20;
const REDUCE_TRANSPARENCY = "(prefers-reduced-transparency: reduce)";

type Surface = { element: Element; look: Partial<GlassLook> | undefined; onDrawn: (drawn: boolean) => void };

/** Whether the engine draws a surface's glass right now, and why not. */
export type PageGlassState = {
  drawing: boolean;
  surfaces: number;
  reason: "drawing" | "no-surface" | "no-still" | "reduce-transparency" | "no-webgl2";
};

class PageGlass {
  private readonly view: Window;
  private readonly surfaces = new Map<Element, Surface>();
  private backdrop: BackdropState;
  private image: HTMLImageElement | null = null;
  private imageKey: string | null = null;
  private imageReady = false;
  private canvas: HTMLCanvasElement | null = null;
  private engine: GlassEngine | null = null;
  private capable = true;
  private resizeObserver: ResizeObserver | null = null;
  private readonly reduceQuery: MediaQueryList | null;
  private frame = 0;
  private stable = 0;
  private last = "";
  private drawing = false;

  constructor(private readonly doc: Document) {
    this.view = doc.defaultView!;
    this.backdrop = readBackdrop(this.view);
    this.reduceQuery = typeof this.view.matchMedia === "function" ? this.view.matchMedia(REDUCE_TRANSPARENCY) : null;
    this.reduceQuery?.addEventListener("change", this.reconcile);
    this.view.addEventListener(BACKDROP_EVENT, this.onBackdrop);
  }

  state(): PageGlassState {
    const reason = this.reason();
    return { drawing: this.drawing, surfaces: this.surfaces.size, reason };
  }

  private reason(): PageGlassState["reason"] {
    if (!this.capable) return "no-webgl2";
    if (this.surfaces.size === 0) return "no-surface";
    if (this.reduceQuery?.matches || this.doc.documentElement.hasAttribute("data-reduce-transparency"))
      return "reduce-transparency";
    if (!this.backdrop.image || !this.backdrop.rect) return "no-still";
    return "drawing";
  }

  register(element: Element, look: Partial<GlassLook> | undefined, onDrawn: (drawn: boolean) => void): () => void {
    this.surfaces.set(element, { element, look, onDrawn });
    this.resizeObserver?.observe(element);
    this.reconcile();
    if (this.drawing) {
      element.setAttribute(GLASS_ENGINE_ATTRIBUTE, "");
      onDrawn(true);
    }
    return () => {
      if (this.surfaces.get(element)?.onDrawn !== onDrawn) return;
      this.surfaces.delete(element);
      this.resizeObserver?.unobserve(element);
      element.removeAttribute(GLASS_ENGINE_ATTRIBUTE);
      this.reconcile();
      this.invalidate();
    };
  }

  update(element: Element, look: Partial<GlassLook> | undefined): void {
    const surface = this.surfaces.get(element);
    if (!surface) return;
    surface.look = look;
    this.invalidate();
  }

  private readonly onBackdrop = () => {
    this.backdrop = readBackdrop(this.view);
    this.reconcile();
    this.invalidate();
  };

  private readonly reconcile = () => {
    const want = this.reason() === "drawing";
    if (want) {
      this.start();
      // No WebGL2: start() left no engine, and the still is not even decoded.
      if (this.engine) this.loadImage();
    } else this.stop();
    this.setDrawing(want && this.imageReady && this.engine !== null);
  };

  private setDrawing(drawing: boolean): void {
    if (drawing === this.drawing) return;
    this.drawing = drawing;
    for (const surface of this.surfaces.values()) {
      if (drawing) surface.element.setAttribute(GLASS_ENGINE_ATTRIBUTE, "");
      else surface.element.removeAttribute(GLASS_ENGINE_ATTRIBUTE);
      surface.onDrawn(drawing);
    }
  }

  private loadImage(): void {
    const { image, key } = this.backdrop;
    if (!image || key === this.imageKey) return;
    this.imageKey = key;
    this.imageReady = false;
    const next = new Image();
    next.onload = () => {
      if (this.image !== next || !this.engine) return;
      this.engine.setBackdrop(next, this.backdrop.rect);
      this.imageReady = true;
      this.reconcile();
      this.invalidate();
    };
    this.image = next;
    next.src = image;
  }

  private start(): void {
    if (this.canvas || !this.capable) return;
    const canvas = this.doc.createElement("canvas");
    canvas.setAttribute("aria-hidden", "true");
    canvas.dataset.cmuxGlassEngine = "";
    canvas.style.cssText =
      "position:fixed;inset:0;width:100%;height:100%;z-index:var(--layer-backdrop, -1);pointer-events:none;contain:strict;";
    const engine = GlassEngine.create(canvas);
    if (!engine) {
      this.capable = false;
      return;
    }
    this.canvas = canvas;
    this.engine = engine;
    this.doc.documentElement.append(canvas);
    this.resizeObserver = new ResizeObserver(this.invalidate);
    for (const element of this.surfaces.keys()) this.resizeObserver.observe(element);
    this.doc.addEventListener("scroll", this.invalidate, { capture: true, passive: true });
    this.view.addEventListener("resize", this.onResize);
    this.doc.addEventListener("transitionrun", this.invalidate, { capture: true, passive: true });
    this.doc.addEventListener("animationstart", this.invalidate, { capture: true, passive: true });
    this.onResize();
  }

  private stop(): void {
    if (!this.canvas) return;
    if (this.frame) this.view.cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.doc.removeEventListener("scroll", this.invalidate, { capture: true });
    this.view.removeEventListener("resize", this.onResize);
    this.doc.removeEventListener("transitionrun", this.invalidate, { capture: true });
    this.doc.removeEventListener("animationstart", this.invalidate, { capture: true });
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.engine?.dispose();
    this.engine = null;
    this.canvas.remove();
    this.canvas = null;
    this.image = null;
    this.imageKey = null;
    this.imageReady = false;
    this.last = "";
  }

  private readonly onResize = () => {
    this.engine?.resize(this.view.innerWidth, this.view.innerHeight, this.view.devicePixelRatio || 1);
    if (this.imageReady && this.image) this.engine?.setBackdrop(this.image, this.backdrop.rect);
    this.last = "";
    this.invalidate();
  };

  private readonly invalidate = () => {
    this.stable = 0;
    if (!this.frame && this.engine) this.frame = this.view.requestAnimationFrame(this.tick);
  };

  // perf-hot: 4ms glass-engine.page-frame
  private readonly tick = () => {
    this.frame = 0;
    const engine = this.engine;
    if (!engine || !this.drawing) return;
    // One pass of reads, no writes between them.
    const layers: GlassLayer[] = [];
    for (const surface of this.surfaces.values()) {
      const box = surface.element.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) continue;
      layers.push({ x: box.x, y: box.y, width: box.width, height: box.height, look: surface.look });
    }
    const key = JSON.stringify(layers);
    if (key !== this.last) {
      this.last = key;
      this.stable = 0;
      engine.render(layers, "layers");
    } else this.stable += 1;
    if (this.stable < STABLE_FRAMES) this.frame = this.view.requestAnimationFrame(this.tick);
  };
}

const drivers = new WeakMap<Document, PageGlass>();

function driver(doc: Document): PageGlass {
  let found = drivers.get(doc);
  if (!found) {
    found = new PageGlass(doc);
    drivers.set(doc, found);
  }
  return found;
}

/** Draws `element`'s glass with the engine while it can; `onDrawn` hears whether it does (the
 * surface's CSS glass stands down while it does). Returns the unregister. */
export function registerGlassSurface(
  element: Element,
  look: Partial<GlassLook> | undefined,
  onDrawn: (drawn: boolean) => void,
): () => void {
  return driver(element.ownerDocument).register(element, look, onDrawn);
}

/** A registered surface's new look. */
export function updateGlassSurface(element: Element, look: Partial<GlassLook> | undefined): void {
  drivers.get(element.ownerDocument)?.update(element, look);
}

/** The page's engine state, for tests and the Debug glass readout. */
export function pageGlassState(doc: Document = document): PageGlassState {
  return drivers.get(doc)?.state() ?? { drawing: false, surfaces: 0, reason: "no-surface" };
}
