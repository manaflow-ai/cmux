// Hold to approve (holdToApprove.experiment.ts, off by default): an allow button that answers only
// after it is held. The pointer held on it, Return or Space held while it has focus, or the card's own
// keys (y, a, Return, ⌘↩) held, fill a ring at the button's leading edge over the hold time; letting go
// early, leaving the window or losing focus cancels for free. When the experiment is off the cards
// call none of this and keep today's click.
import React, { useEffect, useRef, useState } from "react";
import { motionMode } from "../../../ui/motion/motionMode";
import { holdProgress, REDUCED_STEPS } from "./holdToApprove";
import "./holdButton.css";

export type HoldPhase = "idle" | "holding" | "done";

type HoldBind = Pick<
  React.ButtonHTMLAttributes<HTMLButtonElement>,
  | "onPointerDown"
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
  durationMs,
  disabled = false,
  onComplete,
  reducedOverride,
}: {
  enabled: boolean;
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
  complete.current = onComplete;
  const run = useRef<{ phase: HoldPhase; stop: () => void }>({ phase: "idle", stop: () => undefined });

  const stop = () => {
    run.current.stop();
    run.current.stop = () => undefined;
  };
  const cancel = () => {
    if (run.current.phase !== "holding") return;
    stop();
    run.current.phase = "idle";
    setPhase("idle");
    setProgress(0);
  };
  const start = (releaseKey?: string): boolean => {
    if (disabled || run.current.phase !== "idle") return false;
    const doc = ref.current?.ownerDocument ?? (typeof document === "undefined" ? undefined : document);
    const view = doc?.defaultView ?? undefined;
    const stepped = reducedOverride ?? motionMode(doc, ref.current) !== "full";
    const began = performance.now();
    const timers: (() => void)[] = [];
    run.current.phase = "holding";
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
      stop();
      run.current.phase = "done";
      setPhase("done");
      setProgress(1);
      const reset = setTimeout(() => {
        if (run.current.phase !== "done") return;
        run.current.phase = "idle";
        setPhase("idle");
        setProgress(0);
      }, DONE_RESET_MS);
      run.current.stop = () => clearTimeout(reset);
      complete.current();
    }, durationMs);
    timers.push(() => clearTimeout(done));
    if (releaseKey !== undefined && doc && view) {
      // The card's key was pressed anywhere in the page: its release anywhere ends the hold.
      const onUp = (event: KeyboardEvent) => {
        if (event.code === releaseKey) cancel();
      };
      const onBlur = () => cancel();
      doc.addEventListener("keyup", onUp, true);
      view.addEventListener("blur", onBlur);
      timers.push(() => {
        doc.removeEventListener("keyup", onUp, true);
        view.removeEventListener("blur", onBlur);
      });
    }
    run.current.stop = () => timers.forEach((clear) => clear());
    return true;
  };

  // Disabled mid-hold (the card went busy) or off: nothing may complete.
  useEffect(() => {
    if (disabled || !enabled) cancel();
  });
  useEffect(() => () => stop(), []);

  if (!enabled) return undefined;
  return {
    progress,
    phase,
    reduced: reducedOverride ?? reduced,
    ref,
    holdKey(event) {
      if (event.repeat) return;
      start(event.code);
    },
    bind: {
      onPointerDown(event) {
        if (event.button !== 0) return;
        event.currentTarget.setPointerCapture?.(event.pointerId);
        start();
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
