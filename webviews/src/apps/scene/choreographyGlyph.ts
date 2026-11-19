// Draws a `cmux.particles/1` choreography (choreography.ts) into an element: one absolutely placed
// span per dot, moved only by `transform` (translate and scale), so a frame never lays out or paints
// beyond the compositor. Every glyph on the page shares one requestAnimationFrame clock, which runs
// only while some glyph is on screen, the page is visible and motion is full; Reduce Motion, calm motion
// and `ui.animationSpeed: off` hold the glyph on its still (the first frame of what would play).
// The scene's `Particles` node (SceneChoreography.tsx) and any other web surface mount it the same way.
import "./choreographyGlyph.css";
import { sceneMotionEnv, type SceneMotionEnv } from "./motionProps";
import { ChoreographyPlayer, type ChoreoDot, type ChoreoRequest, type Choreography } from "./choreography";

export type ChoreographyGlyphOptions = {
  /** Points; overrides `particle.size`. */
  size?: number;
  /** A CSS color (a resolved scene token); overrides `particle.color`. */
  color?: string;
};

type Glyph = {
  player: ChoreographyPlayer;
  dots: HTMLSpanElement[];
  /** Each span's last written transform: a dot that holds still costs no style write. */
  written: string[];
  size: number;
  onScreen: boolean;
  /** Player time (ms): page time scaled by `ui.animationSpeed`, so a slower speed plays slower. */
  clock: { page: number; player: number };
};

const glyphs = new Set<Glyph>();
let frame = 0;
let env: SceneMotionEnv | null = null;
let frameView: (Window & typeof globalThis) | null = null;

function place(glyph: Glyph, dots: readonly ChoreoDot[]): void {
  for (let index = 0; index < glyph.dots.length; index += 1) {
    const span = glyph.dots[index]!;
    const dot = dots[index];
    // Spans are `size` square, centred on the glyph's centre; scale is over `size`.
    const transform =
      !dot || dot.s <= 0
        ? "scale(0)"
        : `translate(${dot.x.toFixed(2)}px, ${dot.y.toFixed(2)}px) scale(${dot.s.toFixed(3)})`;
    if (glyph.written[index] === transform) continue;
    glyph.written[index] = transform;
    span.style.transform = transform;
  }
}

function playerTime(glyph: Glyph, now: number, speed: number): number {
  glyph.clock.player += (now - glyph.clock.page) / speed;
  glyph.clock.page = now;
  return glyph.clock.player;
}

function tick(now: number): void {
  frame = 0;
  const view = frameView;
  if (!view || !env || env.mode !== "full") return;
  let running = false;
  for (const glyph of glyphs) {
    if (!glyph.onScreen) {
      glyph.clock.page = now;
      continue;
    }
    running = true;
    place(glyph, glyph.player.sample(playerTime(glyph, now, env.speed)));
  }
  if (running) frame = view.requestAnimationFrame(tick);
}

/** Starts the shared clock when a glyph can move, or holds every glyph on its still when none may. */
function recheck(doc: Document): void {
  const view = doc.defaultView;
  if (!view) return;
  env = sceneMotionEnv(doc);
  frameView = view as Window & typeof globalThis;
  if (env.mode !== "full") {
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    for (const glyph of glyphs) place(glyph, glyph.player.still());
    return;
  }
  const now = view.performance.now();
  for (const glyph of glyphs) glyph.clock.page = now;
  if (!frame && [...glyphs].some((glyph) => glyph.onScreen)) frame = view.requestAnimationFrame(tick);
}

let watching: { doc: Document; stop: () => void } | null = null;

function watchSwitches(doc: Document): void {
  if (watching?.doc === doc) return;
  watching?.stop();
  const view = doc.defaultView;
  if (!view) return;
  const again = () => recheck(doc);
  const switches = typeof view.MutationObserver === "function" ? new view.MutationObserver(again) : undefined;
  switches?.observe(doc.documentElement, {
    attributes: true,
    attributeFilter: ["data-cmux-motion", "data-agent-motion", "style"],
  });
  const reduced = view.matchMedia?.("(prefers-reduced-motion: reduce)");
  reduced?.addEventListener?.("change", again);
  doc.addEventListener("visibilitychange", again);
  watching = {
    doc,
    stop: () => {
      switches?.disconnect();
      reduced?.removeEventListener?.("change", again);
      doc.removeEventListener("visibilitychange", again);
    },
  };
}

/** Mounts a glyph into `host` (emptied); returns its controls. The host should be `position: relative`. */
export function mountChoreographyGlyph(
  host: HTMLElement,
  doc: Choreography,
  request: ChoreoRequest,
  options: ChoreographyGlyphOptions = {},
): { setRequest: (request: ChoreoRequest) => void; unmount: () => void; player: ChoreographyPlayer } {
  const owner = host.ownerDocument;
  const view = owner.defaultView;
  const size = options.size && options.size > 0 ? options.size : doc.size;
  const now = view?.performance.now() ?? 0;
  const glyph: Glyph = {
    player: new ChoreographyPlayer(doc, request, now),
    dots: [],
    written: [],
    size,
    onScreen: false,
    clock: { page: now, player: now },
  };
  host.replaceChildren();
  for (let index = 0; index < doc.max; index += 1) {
    const span = owner.createElement("span");
    span.className = "cmux-choreography-dot";
    span.dataset.shape = doc.shape;
    span.style.width = `${size}px`;
    span.style.height = `${size}px`;
    span.style.marginLeft = `${-size / 2}px`;
    span.style.marginTop = `${-size / 2}px`;
    span.style.background = options.color ?? "currentColor";
    span.style.transform = "scale(0)";
    host.append(span);
    glyph.dots.push(span);
  }
  glyphs.add(glyph);
  place(glyph, glyph.player.still());
  watchSwitches(owner);
  // No observer: a host that cannot say the glyph is on screen keeps it on its still.
  const visibility =
    view && typeof view.IntersectionObserver === "function"
      ? new view.IntersectionObserver((entries) => {
          glyph.onScreen = entries.some((entry) => entry.isIntersecting);
          recheck(owner);
        })
      : undefined;
  visibility?.observe(host);
  return {
    player: glyph.player,
    setRequest: (next) => glyph.player.setRequest(next),
    unmount: () => {
      visibility?.disconnect();
      glyphs.delete(glyph);
      host.replaceChildren();
      if (!glyphs.size) {
        if (frame) frameView?.cancelAnimationFrame(frame);
        frame = 0;
        watching?.stop();
        watching = null;
      }
    },
  };
}
