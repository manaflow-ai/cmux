// A new chat settles in (Leo, 2026-11-22: "claude code has such a nice animation on startup... it's so
// smooth and nice... I WANT US TO HAVE SHIT LIKE THAT TOO"): the hero's question, the line under it,
// the home lists and the composer rise into place on one spring, a few tens of milliseconds apart.
//
// Nothing waits on it. The parts are mounted, laid out and focusable in the commit that mounts the
// hero; only their transform and opacity move, from Web Animations the hero's layout effect starts.
// The composer takes keys and focus at frame 0 (no pointer-events, no inert, no delayed focus or
// mount). The entrance holds at time zero through the next render and is released from a task that
// frame posts (conversation/entranceClock.ts holdForFirstFrame; handbook
// animation-releases-before-first-observed-frame.md), so the first frame drawn is the start state.
// An unmount cancels the hold and the animations, so a sent first message draws the composer at rest.
// Reduce Motion, the app's motion switch and a hidden page play nothing: everything is drawn at rest.
//
// The spring matches the iOS app's new chat (response 0.42 s, damping 0.82): sampled into a CSS
// `linear()` easing, with a cubic-bezier approximation where WebKit has no `linear()`.

import { springEasing, motionMode } from "../../ui/motion/motionMode";
import { holdForFirstFrame, type Frames, windowFrames } from "./conversation/entranceClock";

export type NewChatEntrance = "rise" | "bloom" | "focus" | "off";

/** The default: the stagger the iOS new chat plays. */
export const NEW_CHAT_ENTRANCE: NewChatEntrance = "rise";

/**
 * A spring with response 0.42 s and damping 0.82 (SwiftUI `.spring(response: 0.42, dampingFraction:
 * 0.82)`), sampled every 20 ms over its 360 ms run: 1 - e^(-ζωt)(cos ω_d t + ζω/ω_d sin ω_d t). It
 * reaches its end at about 300 ms and passes it by 1% at most (a tenth of a pixel on the rise).
 */
export const NEW_CHAT_SPRING =
  "linear(0, 0.038 5.56%, 0.129 11.1%, 0.246 16.7%, 0.37 22.2%, 0.49 27.8%, 0.6 33.3%, 0.695 38.9%, 0.775 44.4%, 0.839 50%, 0.89 55.6%, 0.929 61.1%, 0.958 66.7%, 0.978 72.2%, 0.992 77.8%, 1 83.3%, 1.01 88.9%, 1.01 94.4%, 1)";
/** The same spring where `linear()` is missing (WebKit before Safari 17.2): within 2% of it throughout. */
export const NEW_CHAT_SPRING_FALLBACK = "cubic-bezier(0.3, 0.25, 0.2, 1.05)";
/** One part's run (ms); the last part starts two staggers in, so the whole entrance is at rest by 440 ms. */
export const NEW_CHAT_PART_MS = 360;
/** Between one part's start and the next (ms). */
export const NEW_CHAT_STAGGER_MS = 40;

/** What moves, top to bottom; the composer is outside the hero, in the pane's dock. */
const PARTS = {
  // The plain new chat's repo tour offer (EmptyState.tsx), when its folder has one.
  title: ".acpmux-empty-title-anchor",
  sub: ".acpmux-empty-choose",
} as const;
const DOCK_PARTS = {
  home: ".acpmux-dock > .acpmux-home-area",
  composer: ".acpmux-dock > .acpmux-composer",
} as const;

type Part = { element: Element; delay: number; from: Keyframe; to: Keyframe };

const rest: Keyframe = { opacity: 1, transform: "none" };

/** The parts `style` moves, read from the hero and the pane around it. */
export function newChatEntranceParts(hero: Element, style: Exclude<NewChatEntrance, "off">): Part[] {
  const pane = hero.closest(".acpmux-main") ?? hero.parentElement?.parentElement ?? undefined;
  const title = hero.querySelector(PARTS.title);
  const sub = hero.querySelector(PARTS.sub);
  const home = pane?.querySelector(DOCK_PARTS.home) ?? null;
  const composer = pane?.querySelector(DOCK_PARTS.composer) ?? null;
  const parts: Part[] = [];
  const add = (element: Element | null, delay: number, from: Keyframe, to: Keyframe = rest) => {
    if (element) parts.push({ element, delay, from, to });
  };
  const step = NEW_CHAT_STAGGER_MS;
  // The composer is never drawn invisible: a key typed at frame 0 shows in it at once.
  const composerFrom: Keyframe = { opacity: 0.4, transform: "translateY(8px)" };
  if (style === "rise") {
    add(title, 0, { opacity: 0, transform: "translateY(10px) scale(0.985)" });
    add(sub, step, { opacity: 0, transform: "translateY(10px)" });
    add(home, step * 2, { opacity: 0, transform: "translateY(10px)" });
    add(composer, step * 2, composerFrom);
  } else if (style === "bloom") {
    // The question grows from its center, then the rest follows on the same spring.
    add(title, 0, { opacity: 0, transform: "scale(0.92)" });
    add(sub, step * 2, { opacity: 0, transform: "translateY(6px)" });
    add(home, step * 2, { opacity: 0, transform: "translateY(6px)" });
    add(composer, step * 2, composerFrom);
  } else {
    // Out of focus to sharp: a blur on the hero only (the composer's text stays sharp to type into).
    add(
      title,
      0,
      { opacity: 0, filter: "blur(8px)", transform: "scale(1.02)" },
      { opacity: 1, filter: "blur(0)", transform: "none" },
    );
    add(sub, step, { opacity: 0, filter: "blur(6px)" }, { opacity: 1, filter: "blur(0)" });
    add(home, step * 2, { opacity: 0, filter: "blur(6px)" }, { opacity: 1, filter: "blur(0)" });
    add(composer, step * 2, composerFrom);
  }
  return parts;
}

/** The chats (by key) whose entrance this document already played: a hero mounted again is at rest. */
const played = new Set<string>();

/**
 * Whether the hero of chat `key` should play its entrance now, and marks it played: once per chat,
 * so a hero remounted by the same chat (the harness picker closing, a reconnect, a switch back)
 * is drawn at rest. No key: every mount plays (the gallery, tests).
 */
export function claimNewChatEntrance(key: string | undefined): boolean {
  if (key === undefined) return true;
  if (played.has(key)) return false;
  played.add(key);
  return true;
}

/** Tests only: forget which chats played. */
export function resetNewChatEntranceClaims(): void {
  played.clear();
}

export type NewChatEntrancePlay = { readonly animations: readonly Animation[]; stop(): void };

/**
 * Plays `style` on the hero `hero` (EmptyState's root) and the composer under it, held through the
 * next frame. Called in the hero's mount layout effect; the returned `stop` is its cleanup.
 */
export function playNewChatEntrance(
  hero: HTMLElement | null,
  style: NewChatEntrance = NEW_CHAT_ENTRANCE,
  frames: Frames | undefined = windowFrames(),
): NewChatEntrancePlay | undefined {
  if (!hero || style === "off" || typeof hero.animate !== "function") return undefined;
  if (motionMode(hero.ownerDocument, hero) !== "full") return undefined;
  const easing = springEasing(NEW_CHAT_SPRING, NEW_CHAT_SPRING_FALLBACK, hero.ownerDocument);
  const animations = newChatEntranceParts(hero, style).map((part) =>
    // motion-allow: the iOS new chat's spring (response 0.42 s) runs 360 ms, past the scale's large step; one entrance per new chat, matched across iOS and web (Leo 2026-11-22).
    part.element.animate([part.from, part.to], {
      duration: NEW_CHAT_PART_MS,
      delay: part.delay,
      easing,
      // Before its delay a part is drawn at its start, so nothing shows whole and then jumps back.
      fill: "backwards",
    }),
  );
  const release = holdForFirstFrame(animations, frames);
  return {
    animations,
    stop() {
      release();
      for (const animation of animations) animation.cancel();
    },
  };
}
