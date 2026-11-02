// Chat switch choreography (chatSwitch.experiment.ts; Leo, 2026-11-01: "honestly i just want to be
// able to be able to eventually play full-on animations like this"). When the pane opens another
// chat, the transcript's visible rows, the chat title and Session Info's body move as one short
// performance on one spring, instead of the transcript fading alone (a cold open) or nothing moving
// (a cached one).
//
// Rules it keeps (leo-workspace design/motion-and-polish.md): transform and opacity only, so every
// frame is the compositor's; everything settled within the 240 ms ceiling; the switch itself is not
// delayed (the new chat is in the DOM on the frame the switch lands, the motion plays over it);
// interruptible: a switch during a switch starts each element from where it is now. No timer,
// observer or frame loop: Web Animations that finish on their own, and stop() cancels them (the
// transcript calls it on the next switch and on unmount). Motion off or a zero motion token: nothing.
// Reduce Motion: the same elements fade, with no travel.
import { MOTION_MS } from "../../motion/scale.generated";
import { entranceAllowed } from "../shared/pageReveal";
import type { ChatSwitchArm } from "./chatSwitch.experiment";

/** One spring for every part (critically damped, a touch of settle), as a `linear()` easing. */
export const SWITCH_SPRING = "linear(0, 0.21 6%, 0.53 14%, 0.78 24%, 0.92 34%, 0.985 46%, 1.006 58%, 1.004 72%, 1)";
/** Rows staggered at most: past that the remaining rows move with the last. */
const MAX_STAGGERED_ROWS = 8;
const STAGGER_MS = 16;
const RISE_PX = 6;
const SIDE_PX = 8;

export type ChatSwitchPlay = { stop(): void; readonly animations: readonly Animation[] };

type Part = { element: Element; delay: number; duration: number; from: Keyframe; to: Keyframe };

/** Whether the host lets the pane move: not off, not a zero fade-in token, page shown. */
function motionMode(doc: Document): "full" | "reduced" | "none" {
  const root = doc.documentElement;
  const view = doc.defaultView;
  if (!view || !entranceAllowed(doc)) return "none";
  if (root.dataset.cmuxMotion === "off") return "none";
  const token = view.getComputedStyle(root).getPropertyValue("--agent-motion-in").trim();
  if (token && !(Number.parseFloat(token) > 0)) return "none";
  if (root.dataset.cmuxMotion === "reduced" || view.matchMedia?.("(prefers-reduced-motion: reduce)").matches)
    return "reduced";
  return "full";
}

/** The rows on screen in the scroller, bottom first (the reading position settles first). */
function visibleRows(scroller: HTMLElement): HTMLElement[] {
  const view = scroller.getBoundingClientRect();
  const rows: HTMLElement[] = [];
  for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row")) {
    const box = row.getBoundingClientRect();
    if (box.height > 0 && box.bottom > view.top && box.top < view.bottom) rows.push(row);
  }
  return rows.sort((a, b) => b.getBoundingClientRect().top - a.getBoundingClientRect().top);
}

/** The parts each arm moves, read in one pass (no layout writes until every rect is read). */
export function chatSwitchParts(scroller: HTMLElement, arm: Exclude<ChatSwitchArm, "off">, reduced: boolean): Part[] {
  const doc = scroller.ownerDocument;
  const title = doc.querySelector(".acpmux-thread-title");
  const info = doc.querySelector("aside.acpmux-session-info .acpmux-session-info__body");
  const parts: Part[] = [];
  const fade = (element: Element | null, delay = 0, duration: number = MOTION_MS.micro) => {
    if (element) parts.push({ element, delay, duration, from: { opacity: 0 }, to: { opacity: 1 } });
  };
  if (arm === "fade" || reduced) {
    fade(scroller);
    fade(title);
    fade(info);
    return parts;
  }
  if (arm === "depth") {
    const duration = MOTION_MS.standard;
    parts.push({
      element: scroller,
      delay: 0,
      duration,
      from: { opacity: 0, transform: "scale(0.985)" },
      to: { opacity: 1, transform: "none" },
    });
    if (title) parts.push({ element: title, delay: 0, duration, from: { opacity: 0 }, to: { opacity: 1 } });
    if (info)
      parts.push({
        element: info,
        delay: 0,
        duration,
        from: { opacity: 0, transform: `translateX(${SIDE_PX}px)` },
        to: { opacity: 1, transform: "none" },
      });
    return parts;
  }
  // Stagger: the title at once, the rows from the bottom up, Session Info after the first rows.
  const duration = MOTION_MS.standard;
  if (title)
    parts.push({
      element: title,
      delay: 0,
      duration: MOTION_MS.micro,
      from: { opacity: 0, transform: `translateY(${-RISE_PX / 2}px)` },
      to: { opacity: 1, transform: "none" },
    });
  visibleRows(scroller).forEach((row, index) => {
    parts.push({
      element: row,
      delay: Math.min(index, MAX_STAGGERED_ROWS - 1) * STAGGER_MS,
      duration: duration - Math.min(index, MAX_STAGGERED_ROWS - 1) * (STAGGER_MS / 2),
      from: { opacity: 0, transform: `translateY(${RISE_PX}px)` },
      to: { opacity: 1, transform: "none" },
    });
  });
  if (info)
    parts.push({
      element: info,
      delay: STAGGER_MS * 2,
      duration: duration - STAGGER_MS,
      from: { opacity: 0, transform: `translateX(${SIDE_PX}px)` },
      to: { opacity: 1, transform: "none" },
    });
  return parts;
}

/** The value an element is drawn at now (mid-animation included), for an interrupted start. */
function current(element: Element, from: Keyframe): Keyframe {
  const style = element.ownerDocument.defaultView!.getComputedStyle(element);
  const now: Keyframe = {};
  if ("opacity" in from) now.opacity = Number(style.opacity);
  if ("transform" in from) now.transform = style.transform === "none" ? "none" : style.transform;
  return now;
}

/**
 * Plays the switch on `scroller` (the transcript's `.acpmux-scroll`) and the pane around it. `previous`
 * is the last play, still running or not: an element it moves starts from where it is drawn now.
 */
export function playChatSwitch(
  scroller: HTMLElement | null,
  arm: ChatSwitchArm,
  previous?: ChatSwitchPlay,
): ChatSwitchPlay | undefined {
  if (!scroller || arm === "off" || typeof scroller.animate !== "function") {
    previous?.stop();
    return undefined;
  }
  const mode = motionMode(scroller.ownerDocument);
  if (mode === "none") {
    previous?.stop();
    return undefined;
  }
  const parts = chatSwitchParts(scroller, arm, mode === "reduced");
  // Read where a part still moving is drawn before anything is cancelled (no write between reads).
  // Only a part still in flight starts from its drawn value; one whose motion finished (or never
  // started) is drawn at rest, so reading it would animate between equal values: no motion.
  const moving = new Set(
    previous?.animations
      .filter((animation) => animation.playState === "running" || animation.playState === "paused")
      .map((animation) => (animation.effect as KeyframeEffect | null)?.target),
  );
  const starts = parts.map((part) => (moving.has(part.element) ? current(part.element, part.from) : part.from));
  previous?.stop();
  const animations = parts.map((part, index) =>
    part.element.animate([starts[index]!, part.to], {
      duration: part.duration,
      delay: part.delay,
      easing: mode === "reduced" ? "ease-out" : SWITCH_SPRING,
      // Before its delay a part is drawn at its start, so nothing shows whole and then jumps back.
      fill: "backwards",
    }),
  );
  return {
    animations,
    stop() {
      for (const animation of animations) animation.cancel();
    },
  };
}
