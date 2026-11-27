// A one-line label that is cut short scrolls once to show its end while the pointer rests on it (or
// it has keyboard focus): the tabs' and the workspace sidebar's marquee (ui/titleFade.ts, the port of
// cmux-next's MotionMarquee), for labels that clip with an ellipsis in place. Leo, 2026-11-27, on
// "m5pro-24...." and a cut subagent title in the composer: "let's also just do a proper 'it shows all
// the way, and when you hover it pushes to the left maybe? we have any animations for that?".
//
// Nothing about the label changes at rest: it keeps its box, its ellipsis and its DOM. While it
// scrolls, `data-marquee` turns its ellipsis off (hoverMarquee.css) and one Web Animation moves its
// first line left by `text-indent`, so a label drawn by React (a TextRoll cell's words, a chip's name)
// needs no inner element. Same clock as the tabs: after 0.6 s at rest it scrolls at 40 px/s until its
// last glyph meets its end, holds 1.2 s, and comes back; leaving springs it back from where it is.
// Reduce Motion or the agent motion policy `off` never starts one. A label that fits never moves.
import { useEffect, type RefObject } from "react";
import { MOTION_SPRINGS, springCurve } from "../files-panel-motion";
import { marqueeKeyframes, marqueeTiming } from "./titleFade";
import "./hoverMarquee.css";

/** Ambient: never holds a gallery step (gallery/frame/experimentRunner.ts), as the tree's marquee. */
export const HOVER_MARQUEE_ID = "cmux-ambient:marquee";

const reducedMotion = (doc: Document) =>
  doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
const motionOff = (doc: Document) => doc.documentElement.dataset.agentMotion === "off";

/** How far `line`'s words run past its box, in px (0 when they fit). */
export function marqueeTravel(line: HTMLElement): number {
  const over = line.scrollWidth - line.clientWidth;
  return over > 0.5 ? Math.ceil(over) : 0;
}

/**
 * Runs the marquee on the clipped labels `lines()` names while the pointer is on `target` or focus
 * is inside it. Returns the cleanup.
 */
export function attachHoverMarquee(target: HTMLElement, lines: () => readonly HTMLElement[]): () => void {
  const doc = target.ownerDocument;
  let running: { line: HTMLElement; animation: Animation }[] = [];
  let hovered = false;
  let focused = false;

  const settle = (line: HTMLElement, animation: Animation) => {
    animation.cancel();
    delete line.dataset.marquee;
  };

  const stop = (animated: boolean) => {
    const was = running;
    running = [];
    for (const { line, animation } of was) {
      // Where the words are now: caught mid-scroll they spring back from there.
      const shown = animated ? Number.parseFloat(getComputedStyle(line).textIndent) || 0 : 0;
      settle(line, animation);
      if (!animated || Math.abs(shown) <= 0.5 || motionOff(doc) || reducedMotion(doc)) continue;
      const { durationMs, progress } = springCurve(MOTION_SPRINGS.disappear);
      line.dataset.marquee = "";
      const back = line.animate(
        progress.map((value, index) => ({
          offset: index / (progress.length - 1),
          textIndent: `${Math.round(shown * (1 - value) * 100) / 100}px`,
        })),
        { duration: durationMs, easing: "linear", id: HOVER_MARQUEE_ID },
      );
      running.push({ line, animation: back });
      back.onfinish = () => {
        running = running.filter((entry) => entry.animation !== back);
        delete line.dataset.marquee;
      };
    }
  };

  const start = () => {
    stop(false);
    if (motionOff(doc)) return;
    const reduce = reducedMotion(doc);
    for (const line of lines()) {
      const travel = marqueeTravel(line);
      const timing = marqueeTiming(travel, reduce);
      if (!timing) continue;
      const { keyframes, duration } = marqueeKeyframes(travel, timing);
      line.dataset.marquee = "";
      const animation = line.animate(
        keyframes.map(({ translate, ...rest }) => ({ ...rest, textIndent: String(translate).split(" ")[0] })),
        { duration, delay: timing.delayMs, id: HOVER_MARQUEE_ID },
      );
      animation.onfinish = () => {
        running = running.filter((entry) => entry.animation !== animation);
        delete line.dataset.marquee;
      };
      running.push({ line, animation });
    }
  };

  const update = () => (hovered || focused ? start() : stop(true));
  const onEnter = () => {
    hovered = true;
    update();
  };
  const onLeave = () => {
    hovered = false;
    update();
  };
  const onFocusIn = () => {
    focused = target.matches(":focus-within");
    if (focused && !hovered) update();
  };
  const onFocusOut = (event: FocusEvent) => {
    if (event.relatedTarget instanceof Node && target.contains(event.relatedTarget)) return;
    focused = false;
    if (!hovered) update();
  };
  // A policy change mid-scroll (`ui.animationSpeed: off`) stops it at once.
  const policy = new MutationObserver(() => {
    if (motionOff(doc)) stop(false);
  });
  policy.observe(doc.documentElement, { attributes: true, attributeFilter: ["data-agent-motion"] });
  target.addEventListener("pointerenter", onEnter);
  target.addEventListener("pointerleave", onLeave);
  target.addEventListener("focusin", onFocusIn);
  target.addEventListener("focusout", onFocusOut);
  return () => {
    policy.disconnect();
    target.removeEventListener("pointerenter", onEnter);
    target.removeEventListener("pointerleave", onLeave);
    target.removeEventListener("focusin", onFocusIn);
    target.removeEventListener("focusout", onFocusOut);
    stop(false);
  };
}

/** `attachHoverMarquee` on `target`'s element, for its lifetime. `lines` reads the labels from it. */
export function useHoverMarquee(
  target: RefObject<HTMLElement | null>,
  lines: (target: HTMLElement) => readonly HTMLElement[],
): void {
  useEffect(() => {
    const node = target.current;
    if (!node || typeof node.animate !== "function") return undefined;
    return attachHoverMarquee(node, () => lines(node));
    // `lines` is a selector read on each hover; a new closure each render must not re-attach.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target]);
}
