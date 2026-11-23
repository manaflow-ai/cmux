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
// - `brush`: a brush stroke paints the new content in from the side it comes from: a soft-edged mask
//   sweeps across it while a streaked accent stroke rides the edge, over --cmux-motion-large. The
//   whole view takes clicks at once (a mask does not change hit-testing); only its paint is late.
// - `none`: nothing moves.
//
// Stop conditions: no timer and no frame loop. Each swap plays finite Web Animations (at most 240 ms)
// that end on their own; the next swap and unmount cancel them. Motion off, a hidden page or a zero
// motion token: nothing moves. Reduce Motion: every look but `none` becomes the fade.
import { type ReactNode, useLayoutEffect, useRef } from "react";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SPRING, MOTION_SPRING_STEP } from "../../motion/scale.generated";
import { cx } from "../cx";
import { motionMode, motionMs, springEasing } from "./motionMode";
import "./motion.css";

export type ViewSwapLook = "fade" | "slide" | "wipe" | "sweep" | "brush" | "none";

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
export function swapFrames(
  look: Exclude<ViewSwapLook, "none">,
  direction: SwapDirection,
): { content?: Keyframe[]; band?: Keyframe[] } {
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
  if (look === "brush") {
    // The mask is 250% of the view wide: opaque on the first 45%, clear past 55%. Moving it from
    // 100% to 0% carries that soft edge from -25% to 125% of the view; the stroke (half the view
    // wide, centred on the edge) runs from -100% to 200% of its own width on the same curve.
    // The mask lives only in the keyframes: at rest the view has none.
    const forward = direction === "forward";
    const image = `linear-gradient(${forward ? 100 : 280}deg, currentColor 45%, transparent 55%)`;
    const reveal = forward ? ["100% 0%", "0% 0%"] : ["0% 0%", "100% 0%"];
    const stroke = forward ? ["-100%", "200%"] : ["200%", "-100%"];
    const mask = (position: string) => ({
      maskImage: image,
      WebkitMaskImage: image,
      maskSize: "250% 100%",
      WebkitMaskSize: "250% 100%",
      maskRepeat: "no-repeat",
      WebkitMaskRepeat: "no-repeat",
      maskPosition: position,
      WebkitMaskPosition: position,
    });
    return {
      content: [mask(reveal[0]!), mask(reveal[1]!)] as Keyframe[],
      band: [{ transform: `translateX(${stroke[0]})` }, { transform: `translateX(${stroke[1]})` }],
    };
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
  // The brush masks an inner layer, so the stroke riding its edge (the layer's sibling) is not masked.
  const layer = useRef<HTMLDivElement>(null);
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
    const doc = element.ownerDocument;
    const timing: KeyframeAnimationOptions =
      chosen === "slide"
        ? {
            duration: motionMs(MOTION_SPRING_STEP, MOTION_MS[MOTION_SPRING_STEP], doc),
            easing: springEasing(MOTION_SPRING, MOTION_EASE_OUT, doc),
          }
        : chosen === "fade"
          ? { duration: motionMs("micro", MOTION_MS.micro, doc), easing: MOTION_EASE_OUT }
          : chosen === "brush"
            ? { duration: motionMs("large", MOTION_MS.large, doc), easing: MOTION_EASE_OUT }
            : { duration: motionMs("standard", MOTION_MS.standard, doc), easing: MOTION_EASE_OUT };
    const target = chosen === "brush" ? layer.current : element;
    if (frames.content && target) playing.current.push(target.animate(frames.content, timing));
    if (frames.band && band.current) playing.current.push(band.current.animate(frames.band, timing));
    for (const animation of playing.current)
      animation.onfinish = () => {
        playing.current = playing.current.filter((other) => other !== animation);
      };
  }, [swapKey, order, look]);

  useLayoutEffect(() => stop, []);

  return (
    <div ref={root} className={cx("ui-view-swap", className)} data-look={look}>
      {look === "brush" ? (
        <div ref={layer} className="ui-view-swap__layer">
          {children}
        </div>
      ) : (
        children
      )}
      {(look === "sweep" || look === "brush") && (
        <span ref={band} className="ui-view-swap__band" data-look={look} aria-hidden="true" />
      )}
    </div>
  );
}
