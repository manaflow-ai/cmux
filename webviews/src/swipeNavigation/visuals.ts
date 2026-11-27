// What a two-finger Back / Forward swipe shows: the page content moves with the fingers, and a pill
// at the edge the swipe comes from (the left edge for Back) says whether there is somewhere to go.
// The pill is the browser tabs' (BrowserSwipeIndicator.swift): an accent capsule with an arrow that
// slides in as the fingers move and is fully in, at full strength, once letting go would navigate;
// with no entry that way it stays at half strength while the content only stretches a little.
//
// Transform and opacity only, never layout. The motion gate rules (`data-cmux-motion`, Reduce
// Motion, ui/motion/motionMode.ts): with motion full the content follows the fingers and springs
// back over `--cmux-motion-standard` (a CSS transition, so the bootstrap's motion rules and speed
// apply, and it is interruptible from where it is); reduced or off, nothing translates, the pill
// stays in place and shows progress and availability by its strength, and every change is one step.
import type { SwipeDirection } from "./gesture";
import { SWIPE } from "./gesture";
import { motionMode } from "../ui/motion/motionMode";

const PILL_WIDTH = 44;
const PILL_HEIGHT = 32;
const PILL_INSET = 16;
const SETTLE = "transform var(--cmux-motion-standard) var(--cmux-ease-out)";
const ARROW: Record<SwipeDirection, string> = { back: "M14 7l-5 5 5 5", forward: "M10 7l5 5-5 5" };

export interface SwipeLook {
  direction: SwipeDirection;
  progress: number;
  available: boolean;
  armed: boolean;
}

/** The pill's strength: half with no entry, three quarters on the way, full once armed. */
export function pillOpacity(look: SwipeLook, moving: boolean): number {
  const level = !look.available ? 0.5 : look.armed ? 1 : 0.75;
  // Without the slide, strength alone shows how far the swipe has come.
  return moving ? level : level * (0.25 + 0.75 * Math.min(look.progress / SWIPE.commit, 1));
}

export class SwipeVisuals {
  private pill: HTMLElement | null = null;
  private moved = false;

  constructor(private readonly doc: Document) {}

  private get content(): HTMLElement | null {
    return this.doc.body;
  }

  private width(): number {
    return this.doc.defaultView?.innerWidth || 1;
  }

  private makePill(): HTMLElement {
    const pill = this.doc.createElement("div");
    pill.setAttribute("aria-hidden", "true");
    pill.dataset.cmuxSwipePill = "";
    Object.assign(pill.style, {
      position: "fixed",
      top: "50%",
      width: `${PILL_WIDTH}px`,
      height: `${PILL_HEIGHT}px`,
      borderRadius: "999px",
      background: "var(--cmux-accent)",
      color: "var(--cmux-on-accent, Canvas)",
      zIndex: "var(--layer-overlay)",
      pointerEvents: "none",
      display: "grid",
      placeItems: "center",
      opacity: "0",
    });
    pill.innerHTML =
      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path/></svg>';
    // On <html>, outside the content that moves.
    this.doc.documentElement.append(pill);
    return pill;
  }

  /** Shows the swipe at `look`. */
  track(look: SwipeLook): void {
    const moving = motionMode(this.doc) === "full";
    const pill = (this.pill ??= this.makePill());
    const back = look.direction === "back";
    pill.style.left = back ? `${PILL_INSET}px` : "";
    pill.style.right = back ? "" : `${PILL_INSET}px`;
    pill.querySelector("path")?.setAttribute("d", ARROW[look.direction]);
    const shown = moving ? Math.min(look.progress / SWIPE.commit, 1) : 1;
    const hiddenBy = (1 - shown) * (PILL_WIDTH + PILL_INSET) * (back ? -1 : 1);
    pill.style.transform = `translate(${hiddenBy}px, -50%) scale(${look.armed ? 1.08 : 1})`;
    pill.style.opacity = String(pillOpacity(look, moving));
    const content = this.content;
    if (!content) return;
    if (!moving) return this.clearContent();
    content.style.transition = "";
    this.moved = true;
    content.style.willChange = "transform";
    content.style.transform = `translate3d(${(back ? 1 : -1) * look.progress * this.width()}px, 0, 0)`;
  }

  /** The swipe let go short of navigating: the content springs back from where it is. */
  springBack(): void {
    this.hidePill();
    const content = this.content;
    if (!content || !this.moved || motionMode(this.doc) !== "full") return this.clearContent();
    content.style.transition = SETTLE;
    content.style.transform = "";
    const done = (event: Event) => {
      if (event.target !== content) return;
      content.removeEventListener("transitionend", done);
      content.removeEventListener("transitioncancel", done);
      // A new swipe took over meanwhile: it owns the content now.
      if (content.style.transition === SETTLE) this.clearContent();
    };
    content.addEventListener("transitionend", done);
    content.addEventListener("transitioncancel", done);
  }

  /**
   * A new gesture began: stops a spring-back where the content is and returns that place as signed
   * progress (+ is Back), so the next swipe continues from it instead of jumping.
   */
  interrupt(): number {
    const content = this.content;
    const view = this.doc.defaultView;
    if (!content || !view || content.style.transition !== SETTLE) return 0;
    const matrix = view.getComputedStyle(content).transform;
    const x = /^matrix\(([^)]+)\)$/.exec(matrix)?.[1]?.split(",")[4];
    const offset = x === undefined ? 0 : Number.parseFloat(x);
    content.style.transition = "";
    content.style.transform = offset ? `translate3d(${offset}px, 0, 0)` : "";
    return Number.isFinite(offset) ? offset / this.width() : 0;
  }

  /** The swipe committed: the pill goes; the content stays where it is until ``reset``. */
  hold(): void {
    this.hidePill();
  }

  /** Everything back at rest in one step (navigated, hidden, or no motion). */
  reset(): void {
    this.hidePill();
    this.clearContent();
  }

  private hidePill(): void {
    if (this.pill) this.pill.style.opacity = "0";
  }

  /** Clears only what a swipe set: a page's own body styles are never touched otherwise. */
  private clearContent(): void {
    const content = this.content;
    if (!content || !this.moved) return;
    this.moved = false;
    content.style.transition = "";
    content.style.transform = "";
    content.style.willChange = "";
  }
}
