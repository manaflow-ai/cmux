// The chat header's top-right icons with motion that carries state (Thunderdome B, "animated and
// expressive"; Leo 2026-11-05 asked whether the top-right icons should be "a little more animated").
// Debug Settings `agentChat.headerMotion` picks a style; `still`, the default, is the shipped header
// with no change at all. The three others build on each other, subtle to bold:
//
// - `animated-cue`: a pressed plate that grows out of its glyph when its panel opens and shrinks back
//   into it when the panel closes, and an activity dot: on Changes (else the first icon) while the
//   chat's turn runs it breathes, and once the turn is over with changes left it holds still.
// - `animated-spring`: the cue, plus an icon that becomes relevant (Changes after the first edit,
//   Preview when a page appears) arrives with the one spring, and the icons beside it glide over to
//   make room instead of jumping.
// - `animated-morph`: the spring, plus a click that opens a panel sends the glyph to the pane's right
//   edge, where it widens into a tab with the button's name: the diff icon becomes the Changes tab.
//   Hovering an icon previews what it opens: where the panel goes and what it shows.
//
// Every motion is transform and opacity only (composited: full refresh rate, no layout per frame),
// interruptible (a new change starts from what is on screen), and idle costs nothing: no timer, no
// frame loop, and the only loop (the breathing dot) runs only while a turn runs. Every motion asks
// `motionMode()`, the pane's motion gate (the host's Motion switch for the agent pane, which sets
// `--agent-motion-in` to 0 when its animations are off, `data-agent-motion`, Reduce Motion and a
// hidden page): off draws every end state at once; Reduce Motion keeps the fades and drops the travel.
import { useLayoutEffect, useRef, type RefObject } from "react";
import { motionMode, springEasing } from "../../../ui/motion/motionMode";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SPRING } from "../../../motion/scale.generated";

/** The header motion styles, in Debug Settings order. */
export const HEADER_MOTION_STYLES = ["still", "animated-cue", "animated-spring", "animated-morph"] as const;
export type HeaderMotionStyle = (typeof HEADER_MOTION_STYLES)[number];

/** The App's value, or `still` for anything else (an older App sends none). */
export function headerMotionOf(value: unknown): HeaderMotionStyle {
  return HEADER_MOTION_STYLES.includes(value as HeaderMotionStyle) ? (value as HeaderMotionStyle) : "still";
}

export const motionCues = (style: HeaderMotionStyle) => style !== "still";
export const motionSprings = (style: HeaderMotionStyle) => style === "animated-spring" || style === "animated-morph";
export const motionMorphs = (style: HeaderMotionStyle) => style === "animated-morph";

/**
 * Where the activity dot sits, and how: on Changes when it shows, else on the right-side panel's
 * toggle (the first icon, whose panel follows the turn); `working` breathes while the turn runs,
 * `pending` holds still while changes wait. Nothing while there is no work.
 */
export function activityCue(
  ids: readonly string[],
  { working, hasChanges }: { working: boolean; hasChanges: boolean },
): { on: "changes" | "panel"; cue: "working" | "pending" } | undefined {
  if (!working && !hasChanges) return undefined;
  return { on: ids.includes("changes") ? "changes" : "panel", cue: working ? "working" : "pending" };
}

/** The x translation a running animation leaves on `element` (0 when none). */
function translateXOf(element: HTMLElement): number {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") return 0;
  try {
    return new DOMMatrixReadOnly(transform).m41;
  } catch {
    return 0;
  }
}

/**
 * Arrivals and room-making for the icons in `host` (each `[data-quick-action]` button): a new icon
 * springs in from a dot, the ones it pushes glide from where they were drawn. Runs after each
 * render, reads only the buttons' boxes, and starts nothing when nothing moved.
 */
export function useIconArrivals(host: RefObject<HTMLElement | null>, style: HeaderMotionStyle, ids: readonly string[]) {
  // Where each icon was laid out at the last render, relative to the host.
  const lefts = useRef(new Map<string, number>());
  const mounted = useRef(false);
  const key = ids.join(" ");
  useLayoutEffect(() => {
    const root = host.current;
    // `still` and `animated-cue` read no boxes at all: the shipped header pays nothing.
    if (!root || !motionSprings(style)) {
      lefts.current = new Map();
      mounted.current = false;
      return;
    }
    const origin = root.getBoundingClientRect().left;
    const buttons = [...root.querySelectorAll<HTMLElement>("[data-quick-action]")];
    const before = lefts.current;
    const after = new Map<string, number>();
    const mode = mounted.current ? motionMode() : "none";
    for (const button of buttons) {
      const id = button.dataset.quickAction!;
      // The box includes a running glide's offset; the layout position is without it.
      const offset = translateXOf(button);
      const laidOut = button.getBoundingClientRect().left - origin - offset;
      after.set(id, laidOut);
      if (mode === "none") continue;
      const was = before.get(id);
      if (was === undefined) {
        for (const running of button.getAnimations()) running.cancel();
        button.animate(
          mode === "full"
            ? [
                { transform: "scale(0.4)", opacity: 0 },
                { transform: "scale(1)", opacity: 1 },
              ]
            : [{ opacity: 0 }, { opacity: 1 }],
          {
            duration: mode === "full" ? MOTION_MS.large : MOTION_MS.micro,
            easing: mode === "full" ? springEasing(MOTION_SPRING, MOTION_EASE_OUT) : MOTION_EASE_OUT,
          },
        );
        continue;
      }
      // Drawn at `was + offset` a moment ago; glide from there to the new place. Reduce Motion: no travel.
      const from = was + offset - laidOut;
      if (mode !== "full" || Math.abs(from) < 0.5) continue;
      for (const running of button.getAnimations()) running.cancel();
      button.animate([{ transform: `translateX(${from}px)` }, { transform: "translateX(0)" }], {
        duration: MOTION_MS.standard,
        easing: springEasing(MOTION_SPRING, MOTION_EASE_OUT),
      });
    }
    lefts.current = after;
    mounted.current = true;
    // `key` stands for `ids`: rerun only when the icons change.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [key, style, host]);
}

/** The ghost a morph is drawing, so a second click finishes it before starting its own. */
let ghost: { element: HTMLElement; animation: Animation } | undefined;

/**
 * Sends `button`'s glyph to the right edge of the page, where it widens into a tab named `label`
 * and fades: the panel the click opened lands there, beside the chat. Only with full motion.
 */
export function morphIntoTab(button: HTMLElement, label: string): void {
  if (motionMode() !== "full") return;
  const doc = button.ownerDocument;
  const view = doc.defaultView;
  if (!view || typeof button.animate !== "function") return;
  if (ghost) {
    ghost.animation.cancel();
    ghost.element.remove();
    ghost = undefined;
  }
  const box = button.getBoundingClientRect();
  const width = 112;
  const element = doc.createElement("div");
  element.className = "acpmux-header-morph";
  element.setAttribute("aria-hidden", "true");
  const glyph = button.querySelector("[data-icon]")?.cloneNode(true);
  if (glyph) element.append(glyph);
  const name = doc.createElement("span");
  name.className = "acpmux-header-morph-label";
  name.textContent = label;
  element.append(name);
  element.style.left = `${box.left}px`;
  element.style.top = `${box.top}px`;
  element.style.width = `${width}px`;
  element.style.height = `${box.height}px`;
  doc.body.append(element);
  // To the page's right edge, the inset of the tab row's own tabs.
  const travel = Math.max(0, doc.documentElement.clientWidth - 8 - width - box.left);
  const square = `inset(0 ${width - box.width}px 0 0 round 6px)`;
  const tab = "inset(0 0 0 0 round 6px)";
  const animation = element.animate(
    [
      { transform: "translateX(0)", clipPath: square, opacity: 1, offset: 0 },
      { transform: `translateX(${travel}px)`, clipPath: tab, opacity: 1, offset: 0.7 },
      { transform: `translateX(${travel}px)`, clipPath: tab, opacity: 0, offset: 1 },
    ],
    { duration: MOTION_MS.large, easing: MOTION_EASE_OUT },
  );
  const current = { element, animation };
  ghost = current;
  const done = () => {
    element.remove();
    if (ghost === current) ghost = undefined;
  };
  animation.onfinish = done;
  animation.oncancel = done;
}
