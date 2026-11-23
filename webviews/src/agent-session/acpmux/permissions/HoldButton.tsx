// Hold to approve (holdToApprove.experiment.ts, off by default): an allow button that answers only
// after it is held. The pointer held on it, Return or Space held while it has focus, or the card's own
// keys (y, a, Return, ⌘↩) held, fill a ring at the button's leading edge over the hold time; letting go
// early, dragging off the button, leaving the window or losing focus cancels for free. Every hold is
// bound to the ask it started on (`identity`): when the card or panel moves on to another ask, or the
// same ask's revision, the hold is cancelled, and a hold that fills checks the identity once more before
// it answers, so a press on one ask can never approve the next. When the experiment is off the cards
// call none of this and keep today's click.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { motionMode } from "../../../ui/motion/motionMode";
import { holdProgress, REDUCED_STEPS } from "./holdToApprove";
import "./holdButton.css";

export type HoldPhase = "idle" | "holding" | "done";

type HoldBind = Pick<
  React.ButtonHTMLAttributes<HTMLButtonElement>,
  | "onPointerDown"
  | "onPointerMove"
  | "onPointerUp"
  | "onPointerCancel"
  | "onLostPointerCapture"
  | "onKeyDown"
  | "onKeyUp"
  | "onClick"
  | "onBlur"
>;

/// One button's hold: what to draw and what to wire.
export type HoldControl = {
  /// How far the ring has filled, 0 to 1.
  progress: number;
  phase: HoldPhase;
  /// The ring steps instead of sweeping (Reduce Motion, or motion off).
  reduced: boolean;
  /// Spread on the button: pointer, Return and Space, and a click that answers nothing.
  bind: HoldBind;
  /// A key the card's own listener took (y, a, Return, ⌘↩): the hold runs until that key goes up.
  holdKey(event: KeyboardEvent): void;
  /// The button, focused when an app shortcut asks for the allow (it cannot be held).
  ref: React.RefObject<HTMLButtonElement | null>;
};

/// A finished hold whose answer did not land (refused, or the card stayed) lets the person hold again.
const DONE_RESET_MS = 1200;

const isButtonKey = (key: string) => key === "Enter" || key === " ";

/**
 * The hold for one allow button, or undefined when `enabled` is false (the card then keeps its click).
 * `onComplete` runs once per hold, when it fills.
 */
export function useHoldToApprove({
  enabled,
  identity,
  durationMs,
  disabled = false,
  onComplete,
  reducedOverride,
}: {
  enabled: boolean;
  /// What the hold approves: the ask and its answer (a card's permission id and option id; a panel's
  /// group id, revision and decision). A hold answers only the identity it started on.
  identity: string;
  durationMs: number;
  disabled?: boolean;
  onComplete: () => void;
  /// The gallery's reduced-motion variant: draws the stepped ring whatever the system says.
  reducedOverride?: boolean;
}): HoldControl | undefined {
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState<HoldPhase>("idle");
  const [reduced, setReduced] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const complete = useRef(onComplete);
  /// The identity shown now, read when a hold fills.
  const current = useRef(identity);
  // Written after each commit, not during render (the React Compiler skips a hook that writes a ref
  // while rendering); a hold's timer and handlers only read them after a commit.
  useLayoutEffect(() => {
    complete.current = onComplete;
    current.current = identity;
  });
  const run = useRef<{ phase: HoldPhase; stop: () => void; identity?: string; pointerId?: number }>({
    phase: "idle",
    stop: () => undefined,
  });

  const stop = () => {
    run.current.stop();
    run.current.stop = () => undefined;
  };
  const reset = () => {
    stop();
    run.current = { phase: "idle", stop: () => undefined };
    setPhase("idle");
    setProgress(0);
  };
  const cancel = () => {
    if (run.current.phase !== "holding") return;
    reset();
  };
  /// Starts a hold. `releaseKey` (a KeyboardEvent code) is the card key that started it, from
  /// `origin`, the element that had focus: its release, its repeats and that element's blur belong
  /// to the hold. `pointerId` is the pointer that pressed the button.
  const start = (from: { releaseKey?: string; origin?: EventTarget | null; pointerId?: number } = {}): boolean => {
    if (disabled || run.current.phase !== "idle") return false;
    const { releaseKey, origin, pointerId } = from;
    const startedOn = current.current;
    const doc = ref.current?.ownerDocument ?? (typeof document === "undefined" ? undefined : document);
    const view = doc?.defaultView ?? undefined;
    const stepped = reducedOverride ?? motionMode(doc, ref.current) !== "full";
    const began = performance.now();
    const timers: (() => void)[] = [];
    run.current = { phase: "holding", stop: () => undefined, identity: startedOn, pointerId };
    setReduced(stepped);
    setPhase("holding");
    setProgress(0);
    const draw = () => setProgress(holdProgress(performance.now() - began, durationMs, stepped));
    if (stepped) {
      // A quarter at a time, no sweep.
      const id = setInterval(draw, durationMs / REDUCED_STEPS);
      timers.push(() => clearInterval(id));
    } else if (view?.requestAnimationFrame) {
      let frame = 0;
      const tick = () => {
        draw();
        frame = view.requestAnimationFrame(tick);
      };
      frame = view.requestAnimationFrame(tick);
      timers.push(() => view.cancelAnimationFrame(frame));
    }
    // The timer, not a frame, decides: a page that draws no frames (hidden, a test) still completes.
    const done = setTimeout(() => {
      // The ask moved on while the timer was due (the effect below cancels on the next commit; a
      // timer can fire first): nothing is answered.
      if (run.current.identity !== startedOn || current.current !== startedOn) {
        reset();
        return;
      }
      stop();
      run.current.phase = "done";
      setPhase("done");
      setProgress(1);
      const backToIdle = setTimeout(() => {
        if (run.current.phase !== "done") return;
        run.current.phase = "idle";
        setPhase("idle");
        setProgress(0);
      }, DONE_RESET_MS);
      run.current.stop = () => clearTimeout(backToIdle);
      complete.current();
    }, durationMs);
    timers.push(() => clearTimeout(done));
    if (view) {
      // Every hold: the window losing focus (another app, a sheet) ends it.
      const onWindowBlur = () => cancel();
      view.addEventListener("blur", onWindowBlur);
      timers.push(() => view.removeEventListener("blur", onWindowBlur));
    }
    if (releaseKey !== undefined && doc) {
      // The card's key was pressed anywhere in the page: its release anywhere ends the hold, and its
      // repeats are the hold's, so none types into the composer while it fills.
      const onUp = (event: KeyboardEvent) => {
        if (event.code === releaseKey) cancel();
      };
      const onDown = (event: KeyboardEvent) => {
        if (event.code !== releaseKey || !event.repeat) return;
        event.preventDefault();
        event.stopPropagation();
      };
      // The repeats are taken at the window's capture, before the document's listeners (the
      // composer's typing-anywhere one among them) see them.
      doc.addEventListener("keyup", onUp, true);
      view?.addEventListener("keydown", onDown, true);
      timers.push(() => {
        doc.removeEventListener("keyup", onUp, true);
        view?.removeEventListener("keydown", onDown, true);
      });
      // The element that had focus when the key went down loses it: the hold ends.
      const element = origin as Element | null | undefined;
      if (element && typeof element.addEventListener === "function" && element !== doc.body) {
        const onOriginBlur = () => cancel();
        element.addEventListener("blur", onOriginBlur);
        timers.push(() => element.removeEventListener("blur", onOriginBlur));
      }
    }
    run.current.stop = () => timers.forEach((clear) => clear());
    return true;
  };

  // Disabled mid-hold (the card went busy) or off: nothing may complete.
  useEffect(() => {
    if (disabled || !enabled) cancel();
  });
  // Another ask, or another revision of it: a hold or a finished ring of the old one is dropped, and
  // the new one needs its own press.
  useEffect(() => {
    if (run.current.phase !== "idle" && run.current.identity !== identity) reset();
  }, [identity]);
  useEffect(() => () => stop(), []);

  if (!enabled) return undefined;
  return {
    progress,
    phase,
    reduced: reducedOverride ?? reduced,
    ref,
    holdKey(event) {
      if (event.repeat) return;
      start({ releaseKey: event.code, origin: event.target });
    },
    bind: {
      onPointerDown(event) {
        if (event.button !== 0) return;
        event.currentTarget.setPointerCapture?.(event.pointerId);
        start({ pointerId: event.pointerId });
      },
      onPointerMove(event) {
        // Capture keeps the pointer's events on the button after it leaves, so its bounds decide:
        // dragging off the button lets go.
        if (run.current.phase !== "holding" || run.current.pointerId !== event.pointerId) return;
        const box = event.currentTarget.getBoundingClientRect();
        const inside =
          event.clientX >= box.left &&
          event.clientX <= box.right &&
          event.clientY >= box.top &&
          event.clientY <= box.bottom;
        if (!inside) cancel();
      },
      onPointerUp: cancel,
      onPointerCancel: cancel,
      onLostPointerCapture: cancel,
      onBlur: cancel,
      onKeyDown(event) {
        if (!isButtonKey(event.key)) return;
        // The button's own Return and Space would click it: the hold answers instead.
        event.preventDefault();
        event.stopPropagation();
        if (!event.repeat) start();
      },
      onKeyUp(event) {
        if (!isButtonKey(event.key)) return;
        event.preventDefault();
        cancel();
      },
      onClick(event) {
        // A pointer's click or a key's never answers: the hold does. A click with no pointer or key
        // behind it (detail 0 and not from Return or Space, which are taken above) comes from
        // assistive technology, which has no way to hold, so it answers.
        event.preventDefault();
        if (event.detail === 0 && run.current.phase === "idle" && !disabled) complete.current();
      },
    },
  };
}

/// The ring at an allow button's leading edge: a faint track and an arc that fills with the hold.
export function HoldRing({ hold }: { hold: Pick<HoldControl, "progress" | "phase" | "reduced"> }) {
  return (
    <svg
      className="acpmux-hold-ring"
      viewBox="0 0 16 16"
      aria-hidden="true"
      data-phase={hold.phase}
      data-reduced={hold.reduced ? "" : undefined}
    >
      <circle className="acpmux-hold-ring-track" cx="8" cy="8" r="6" pathLength={1} />
      <circle
        className="acpmux-hold-ring-fill"
        cx="8"
        cy="8"
        r="6"
        pathLength={1}
        strokeDasharray="1 1"
        strokeDashoffset={1 - hold.progress}
      />
    </svg>
  );
}

/// The button attributes a hold adds: its handlers, the fill's progress and phase for the CSS, and
/// the "Hold to allow" description for assistive technology. `onClick` replaces the button's own;
/// the tooltip is the caller's (holdTitle), so a button's own title is kept.
export function holdButtonProps(hold: HoldControl, description: string) {
  return {
    ...hold.bind,
    ref: hold.ref,
    "data-hold": hold.phase,
    "aria-description": description,
    style: { "--acpmux-hold-progress": hold.progress } as React.CSSProperties,
  };
}

/// A held button's tooltip: its own title, then "Hold to allow".
export const holdTitle = (title: string | undefined, description: string) =>
  [title, description].filter(Boolean).join("\n");
