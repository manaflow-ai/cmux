// A view that swaps its content (a tab's panel, a step of a flow) with a short entrance on the new
// content. The swap itself is never delayed: React commits the new content and it is in the DOM,
// focusable and clickable on the frame the swap lands; the motion plays over it. There is no snapshot
// of the old content (keeping one would leave a dead layer over live content, which is what the View
// Transitions API does and why it is not used here).
//
// Looks (the gallery `ui.motion-view-swap` compares them):
// - `fade`: the new content fades in over --cmux-motion-micro.
// - `slide`: it fades in and travels 8 px from the side it comes from (the later tab from the right),
//   on the one spring.
// - `wipe`: a slanted edge reveals it from the side it comes from, over --cmux-motion-standard. The
//   part not yet revealed is not hit-testable until the edge passes it (at most 180 ms).
// - `sweep`: the content is shown at once and a slanted accent band crosses it once, over
//   --cmux-motion-standard: the stylised wipe with nothing hidden.
// - `none`: nothing moves.
//
// Stop conditions: no timer and no frame loop. Each swap plays finite Web Animations (at most 240 ms)
// that end on their own; the next swap and unmount cancel them. Motion off, a hidden page or a zero
// motion token: nothing moves. Reduce Motion: every look but `none` becomes the fade.
import { type ReactNode, useLayoutEffect, useRef } from "react";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SPRING, MOTION_SPRING_STEP } from "../../motion/scale.generated";
import { cx } from "../cx";
import { motionMode, springEasing } from "./motionMode";
import "./motion.css";

export type ViewSwapLook = "fade" | "slide" | "wipe" | "sweep" | "none";

/** The edge the new content comes from: forward is the later item (the right), back the earlier. */
export type SwapDirection = "forward" | "back";

const SLIDE_PX = 8;
const SLANT = 16; // percent of the width the wipe's edge leans

export type ViewSwapProps = {
  /** Changes when the content is another view. The entrance plays on each change, not on mount. */
  swapKey: string | number;
  /** The view's place among its siblings (a tab's index): it picks the direction. */
  order?: number;
  look?: ViewSwapLook;
  className?: string;
  children: ReactNode;
};

/** The keyframes of one look, coming from `direction`. */
export function swapFrames(look: Exclude<ViewSwapLook, "none">, direction: SwapDirection) {
  const sign = direction === "forward" ? 1 : -1;
  if (look === "fade") return { content: [{ opacity: 0 }, { opacity: 1 }] };
  if (look === "slide")
    return {
      content: [
        { opacity: 0, transform: `translateX(${sign * SLIDE_PX}px)` },
        { opacity: 1, transform: "none" },
      ],
    };
  if (look === "wipe") {
    // The edge leans; it enters from the side the view comes from and leaves past the other.
    const forward = [
      `polygon(0% 0%, 0% 0%, ${-SLANT}% 100%, 0% 100%)`,
      `polygon(0% 0%, ${100 + SLANT}% 0%, 100% 100%, 0% 100%)`,
    ];
    const back = [
      `polygon(100% 0%, 100% 0%, ${100 + SLANT}% 100%, 100% 100%)`,
      `polygon(100% 0%, ${-SLANT}% 0%, 0% 100%, 100% 100%)`,
    ];
    const [from, to] = direction === "forward" ? forward : back;
    return { content: [{ clipPath: from }, { clipPath: to }] };
  }
  // sweep: only the band moves, from just outside one edge to just outside the other.
  return {
    band: [
      { transform: `translateX(${sign * -100}%) skewX(-16deg)` },
      { transform: `translateX(${sign * 100}%) skewX(-16deg)` },
    ],
  };
}

export function ViewSwap({ swapKey, order, look = "slide", className, children }: ViewSwapProps) {
  const root = useRef<HTMLDivElement>(null);
  const band = useRef<HTMLSpanElement>(null);
  const last = useRef<{ key: string | number; order?: number } | null>(null);
  const playing = useRef<Animation[]>([]);

  const stop = () => {
    for (const animation of playing.current) animation.cancel();
    playing.current = [];
  };

  useLayoutEffect(() => {
    const was = last.current;
    last.current = { key: swapKey, order };
    const element = root.current;
    if (!was || was.key === swapKey || !element) return;
    stop();
    const mode = motionMode(element.ownerDocument);
    if (look === "none" || mode === "none") return;
    const direction: SwapDirection =
      order !== undefined && was.order !== undefined && order < was.order ? "back" : "forward";
    const chosen = mode === "reduced" ? "fade" : look;
    const frames = swapFrames(chosen, direction);
    if (frames.content) {
      const timing =
        chosen === "slide"
          ? {
              duration: MOTION_MS[MOTION_SPRING_STEP],
              easing: springEasing(MOTION_SPRING, MOTION_EASE_OUT, element.ownerDocument),
            }
          : { duration: chosen === "fade" ? MOTION_MS.micro : MOTION_MS.standard, easing: MOTION_EASE_OUT };
      playing.current.push(element.animate(frames.content, timing));
    }
    if (frames.band && band.current)
      playing.current.push(
        band.current.animate(frames.band, { duration: MOTION_MS.standard, easing: MOTION_EASE_OUT }),
      );
    for (const animation of playing.current)
      animation.onfinish = () => {
        playing.current = playing.current.filter((other) => other !== animation);
      };
  }, [swapKey, order, look]);

  useLayoutEffect(() => stop, []);

  return (
    <div ref={root} className={cx("ui-view-swap", className)} data-look={look}>
      {children}
      {look === "sweep" && <span ref={band} className="ui-view-swap__band" aria-hidden="true" />}
    </div>
  );
}
