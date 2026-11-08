// How the toast stack moves (moved from CmuxToastMotion.swift): one transition per state change.
//
// - A new toast rises from just below its slot as it fades in (`appear`); the toasts above it slide up
//   from where they are drawn (`move`).
// - A toast that ends fades out where it was (`fadeOut`), out of the layout at once, so the toasts
//   above slide down into its room together.
// - A toast replaced by a newer one with its id goes in one frame (two different toasts never
//   crossfade); when it was the newest, its successor takes its slot in that frame, without arriving.
// - Details on or off, or the floor moving (the message box grew): every toast slides from where it is
//   drawn to its new place.
// - A change mid-motion starts from what is on screen. Only `transform` and `opacity` animate (Web
//   Animations, on the compositor); nothing lays out per frame.
// - The app's motion switch (`data-cmux-motion`), Reduce Motion and a hidden page go through
//   `motionMode`: reduced keeps the fades and drops the movement; none changes everything in one frame.
//
// Cost: at most three toasts and the few fading out; every pass is O(toasts).
import { type RefObject, useLayoutEffect, useRef, useState } from "react";
import { MOTION_FADES, MOTION_SPRINGS } from "../../../files-panel-motion";
import { springSamples } from "../../../motion/syncMotion";
import { motionMode } from "../../../ui/motion/motionMode";
import type { ToastState } from "./types";

/** How far below its slot a new toast starts (CmuxToastMotion.rise). */
export const RISE_PX = 8;

/** A place in the viewport, without any running slide. */
export interface Place {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** A toast still drawn while it fades out, at its last place. */
export interface ExitingToast {
  toast: ToastState;
  place: Place;
  /** Its order among the toasts when it left, for a stable paint order. */
  index: number;
}

export interface ToastPlan {
  /** Serials that arrive (fade in and rise). */
  appear: number[];
  /** Serials that take a gone toast's slot in one frame (its successor under the same id). */
  inPlace: number[];
  /** Toasts that fade out where they were. */
  exit: ToastState[];
  /** Toasts that go in one frame (a newer one with their id took their place). */
  drop: ToastState[];
}

/** What a change from `before` to `after` (both oldest first) does to each toast. Pure. */
export function planToasts(before: readonly ToastState[], after: readonly ToastState[]): ToastPlan {
  const was = new Set(before.map((toast) => toast.serial));
  const now = new Set(after.map((toast) => toast.serial));
  const ids = new Set(after.map((toast) => toast.id));
  const gone = before.filter((toast) => !now.has(toast.serial));
  const newest = before.at(-1);
  const plan: ToastPlan = { appear: [], inPlace: [], exit: [], drop: [] };
  for (const toast of gone) (ids.has(toast.id) ? plan.drop : plan.exit).push(toast);
  for (const toast of after) {
    if (was.has(toast.serial)) continue;
    // The newest toast's successor under its id shows in its slot at once (a repeated toast never
    // blinks out and fades back in).
    const takesSlot =
      newest !== undefined && !now.has(newest.serial) && newest.id === toast.id && toast === after.at(-1);
    (takesSlot ? plan.inPlace : plan.appear).push(toast.serial);
  }
  return plan;
}

function drawnShift(element: HTMLElement): { x: number; y: number } {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") return { x: 0, y: 0 };
  const matrix = new DOMMatrixReadOnly(transform);
  return { x: matrix.m41, y: matrix.m42 };
}

/** `element`'s place in the viewport without its running slide. */
export function layoutPlace(element: HTMLElement): Place {
  const rect = element.getBoundingClientRect();
  const shift = drawnShift(element);
  return { x: rect.left - shift.x, y: rect.top - shift.y, w: rect.width, h: rect.height };
}

const toastElements = (root: HTMLElement) =>
  new Map(
    [...root.querySelectorAll<HTMLElement>("[data-toast-serial]:not([data-toast-exiting])")].map(
      (element) => [Number(element.dataset.toastSerial), element] as const,
    ),
  );

/**
 * Animates the stack in `list` from what it drew to `toasts`. Returns the toasts fading out, which the
 * stack draws (absolutely, at their place) until their fade ends; `onSettled` runs after every change
 * and whenever a fade ends, so the host hears where the toasts rest.
 */
export function useToastMotion(
  list: RefObject<HTMLElement | null>,
  toasts: readonly ToastState[],
  onSettled: () => void,
  /** True from a toast's end until its fading copy is drawn: the stack holds its reports meanwhile. */
  leavingUndrawn: RefObject<boolean>,
): ExitingToast[] {
  const drawn = useRef<readonly ToastState[]>([]);
  const places = useRef(new Map<number, Place>());
  const running = useRef(new Map<number, Animation[]>());
  const [exiting, setExiting] = useState<ExitingToast[]>([]);
  const settled = useRef(onSettled);
  settled.current = onSettled;

  useLayoutEffect(() => {
    const root = list.current;
    if (!root || drawn.current === toasts) return;
    // An engine with no Web Animations (a test DOM) changes everything in one frame.
    const mode = typeof root.animate === "function" ? motionMode(root.ownerDocument) : "none";
    const before = drawn.current;
    const plan = planToasts(before, toasts);
    drawn.current = toasts;
    const elements = toastElements(root);
    // Reads first: how far each toast's running slide still has it from its place. React has already
    // laid the toasts out at their new places, so where one was drawn before this change is its last
    // place plus that offset (review 4 of #37289: read from the new layout, a restack never slid).
    const sliding = new Map<number, { x: number; y: number }>();
    for (const [serial, element] of elements) sliding.set(serial, drawnShift(element));
    for (const animations of running.current.values()) for (const animation of animations) animation.cancel();
    running.current.clear();
    const after = new Map([...elements].map(([serial, element]) => [serial, layoutPlace(element)] as const));
    const previous = places.current;
    places.current = after;

    // Ends: a fade where the toast was; a dropped one is simply gone.
    const leaving =
      mode === "none"
        ? []
        : plan.exit.flatMap((toast) => {
            const place = previous.get(toast.serial);
            const index = before.indexOf(toast);
            return place ? [{ toast, place, index }] : [];
          });
    if (leaving.length > 0) {
      leavingUndrawn.current = true;
      setExiting((current) => [...current, ...leaving]);
    }

    const move = springSamples(MOTION_SPRINGS.move);
    const appear = springSamples(MOTION_SPRINGS.appear);
    const appearing = new Set(plan.appear);
    for (const [serial, element] of elements) {
      const track = (animation: Animation) =>
        running.current.set(serial, [...(running.current.get(serial) ?? []), animation]);
      const is = after.get(serial);
      if (!is) continue;
      if (appearing.has(serial)) {
        if (mode === "none") continue;
        track(element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: MOTION_FADES.fadeIn, easing: "ease-out" }));
        if (mode === "full")
          track(
            element.animate(
              appear.progress.map((value, index) => ({
                offset: index / (appear.progress.length - 1),
                transform: `translateY(${(RISE_PX * (1 - value)).toFixed(2)}px)`,
              })),
              { duration: appear.durationMs },
            ),
          );
        continue;
      }
      const was = previous.get(serial);
      if (!was || mode !== "full") continue;
      // From where it was drawn to its new place: a restack, Details, the floor moving.
      const shift = sliding.get(serial) ?? { x: 0, y: 0 };
      const dy = was.y + shift.y - is.y;
      const dx = was.x + shift.x - is.x;
      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) continue;
      track(
        element.animate(
          move.progress.map((value, index) => ({
            offset: index / (move.progress.length - 1),
            transform: `translate(${(dx * (1 - value)).toFixed(2)}px, ${(dy * (1 - value)).toFixed(2)}px)`,
          })),
          { duration: move.durationMs },
        ),
      );
    }
    // Held while a fading copy is not drawn yet (`leavingUndrawn`): it reports once drawn, below.
    settled.current();
  }, [list, toasts, leavingUndrawn]);

  // Fading copies: placed where their toast was (in the stack's coordinates, which moved), then faded.
  // Each leaves the flow first, then the stack's origin is read (review 5 of #37289: read with the copy
  // still in the bottom-anchored flow, the origin moved by the copy's height once it left).
  useLayoutEffect(() => {
    const root = list.current;
    if (!root) return;
    const fresh = [...root.querySelectorAll<HTMLElement>("[data-toast-exiting]")].flatMap((element) => {
      if (element.dataset.toastFading === "true") return [];
      const serial = Number(element.dataset.toastSerial);
      const gone = exiting.find((item) => item.toast.serial === serial);
      if (!gone) return [];
      element.dataset.toastFading = "true";
      Object.assign(element.style, { position: "absolute", width: `${gone.place.w}px`, pointerEvents: "none" });
      return [{ element, serial, gone }];
    });
    const origin = root.getBoundingClientRect();
    for (const { element, serial, gone } of fresh) {
      Object.assign(element.style, {
        left: `${gone.place.x - origin.left}px`,
        top: `${gone.place.y - origin.top}px`,
      });
      const fade = element.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: MOTION_FADES.fadeOut,
        easing: "ease-out",
        fill: "forwards",
      });
      const done = () => setExiting((current) => current.filter((item) => item.toast.serial !== serial));
      fade.onfinish = done;
      fade.oncancel = done;
    }
    // The stack with its fading copies, and without them once they faded (the host then retires the page).
    leavingUndrawn.current = false;
    settled.current();
  }, [list, exiting, leavingUndrawn]);

  useLayoutEffect(
    () => () => {
      for (const animations of running.current.values()) for (const animation of animations) animation.cancel();
    },
    [],
  );
  return exiting;
}
