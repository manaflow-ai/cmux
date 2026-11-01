// Esc stops a running turn. By default it takes two presses, as in ChatGPT and Claude Code (Leo
// 2026-10-19: "when we want to cancel chats with escape, I think we want to do a double tap"): the
// first arms the stop, and the composer's Stop keeps its glyph, takes the accent and is named
// "Press Esc again to stop"; a second inside the window stops the turn. Any other key, a click, focus moving or the
// window ending disarms it and puts Stop back. Debug Settings' "Esc stops a turn on a double press"
// (Swift AgentPaneTunables.escapeStopDoublePress, the `composer` event's `escapeDoublePress`) turns
// it off, and one press stops the turn again.
import { useEffect, useRef, useState } from "react";

/// How long after the first Esc a second one still stops the turn: browser focus mode's Esc Esc
/// window (plans/cmux-next/focus.md, `KeyRouter.routesFocusModeEscape`).
export const ESCAPE_STOP_WINDOW_MS = 1_600;

export type EscapeStopPress = {
  /// Whether this press stops the turn.
  stop: boolean;
  /// When the stop was armed, if this press left it armed (the hint shows until the window ends).
  armedAt?: number;
};

/// One Esc while a turn runs. `armedAt` is the previous press that armed the stop, if any;
/// `double` is the Debug Settings choice.
export function escapeStopPress(armedAt: number | undefined, now: number, double: boolean): EscapeStopPress {
  if (!double) return { stop: true };
  if (armedAt !== undefined && now - armedAt >= 0 && now - armedAt <= ESCAPE_STOP_WINDOW_MS) return { stop: true };
  return { stop: false, armedAt: now };
}

const MODIFIERS = new Set([
  "Shift",
  "Control",
  "Alt",
  "AltGraph",
  "Meta",
  "CapsLock",
  "Fn",
  "Dead",
  "Process",
  "Unidentified",
]);

/// Where an Esc that reaches the page counts as a press: a question card, which never answers on
/// Esc and leaves it to the double press (plans/cmux-next/agent-questions.md), or a page with
/// nothing focused. Other controls (sidebar rows, tooltips, the minimap) use Esc for themselves
/// without claiming it, so it is not a press there.
export function countsPageEscape(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return true;
  if (target === target.ownerDocument.body || target === target.ownerDocument.documentElement) return true;
  return target.closest(".acpmux-question") !== null;
}

export type EscapeStop = {
  /// Whether the first press armed the stop: Stop is named "Press Esc again to stop".
  armed: boolean;
  /// An Esc the composer took (a held key's repeats are not presses).
  press(repeat: boolean): void;
};

/// The double press's state for one composer. `stoppable` is whether Stop is shown (a turn runs);
/// `session` is the chat, whose switch drops the arm; `pageEscape` lets an Esc that no control took
/// (focus outside the composer, such as in a question card, which leaves Esc to this) count as a
/// press too: off for the Quick Composer, whose page-level Esc hides the panel.
export function useEscapeStop({
  stoppable,
  session,
  double,
  pageEscape,
  onStop,
}: {
  stoppable: boolean;
  session: string | undefined;
  double: boolean;
  pageEscape: boolean;
  onStop(): void;
}): EscapeStop {
  const armedAt = useRef<number | undefined>(undefined);
  const [armed, setArmed] = useState<number | undefined>(undefined);
  const latest = useRef({ stoppable, double, onStop });
  latest.current = { stoppable, double, onStop };

  const disarm = () => {
    if (armedAt.current === undefined) return;
    armedAt.current = undefined;
    setArmed(undefined);
  };
  const press = (repeat: boolean) => {
    if (repeat || !latest.current.stoppable) return;
    const result = escapeStopPress(armedAt.current, Date.now(), latest.current.double);
    armedAt.current = result.armedAt;
    setArmed(result.armedAt);
    if (result.stop) latest.current.onStop();
  };
  const pressRef = useRef(press);
  pressRef.current = press;
  const disarmRef = useRef(disarm);
  disarmRef.current = disarm;

  // A turn that ends (or a prompt typed, which hides Stop) takes the arm with it, and so does a
  // switch to another chat (the composer stays mounted across sessions).
  const armedSession = useRef(session);
  useEffect(() => {
    const switched = armedSession.current !== session;
    armedSession.current = session;
    if (stoppable && !switched) return;
    disarmRef.current();
  }, [stoppable, session]);

  // The window ending puts Stop back.
  useEffect(() => {
    if (armed === undefined) return;
    const timer = window.setTimeout(() => {
      if (armedAt.current === armed) armedAt.current = undefined;
      setArmed((current) => (current === armed ? undefined : current));
    }, ESCAPE_STOP_WINDOW_MS);
    return () => window.clearTimeout(timer);
  }, [armed]);

  // Any other key, a click or focus moving between the presses starts the double press over. The
  // listeners capture, so a control that stops a key or click still disarms.
  useEffect(() => {
    if (armed === undefined) return;
    const doc = document;
    const key = (event: KeyboardEvent) => {
      if (event.key !== "Escape" && !MODIFIERS.has(event.key)) disarmRef.current();
    };
    const other = () => disarmRef.current();
    // ui-allow: any key between the two presses disarms the stop, wherever focus is; no src/ui widget watches the page's keys.
    doc.addEventListener("keydown", key, true);
    doc.addEventListener("pointerdown", other, true);
    doc.addEventListener("focusin", other, true);
    doc.addEventListener("focusout", other, true);
    window.addEventListener("blur", other);
    return () => {
      doc.removeEventListener("keydown", key, true);
      doc.removeEventListener("pointerdown", other, true);
      doc.removeEventListener("focusin", other, true);
      doc.removeEventListener("focusout", other, true);
      window.removeEventListener("blur", other);
    };
  }, [armed]);

  // An Esc no control took, on a question card or with nothing focused (countsPageEscape). Menus,
  // pickers and popovers that own Esc prevent it or stop it; the composer's own Esc is prevented.
  // The decision waits until the whole dispatch is over (a microtask would run between listeners),
  // and the key stays unclaimed, so the pane's own listeners still see it as the card left it.
  useEffect(() => {
    if (!pageEscape || !stoppable) return;
    const timers = new Set<number>();
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (event.isComposing || event.keyCode === 229) return;
      if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
      if (!countsPageEscape(event.target)) return;
      const timer = window.setTimeout(() => {
        timers.delete(timer);
        if (!event.defaultPrevented) pressRef.current(event.repeat);
      }, 0);
      timers.add(timer);
    };
    // ui-allow: an Esc no control claimed is a press of the double press (as useEscapeToDismiss reads it); no src/ui widget offers this.
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, [pageEscape, stoppable]);

  return { armed: armed !== undefined && stoppable, press };
}
