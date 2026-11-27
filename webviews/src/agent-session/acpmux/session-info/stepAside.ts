// Session Info steps aside for what a row opened (Lucas, 2026-11-06: "if the person presses on changes
// or output or folder, the session summary closes, but when they close that window, it comes back"):
// Environment's folder (the Files tab beside the chat), its Changes (the folder's diff beside it) and
// an Outputs file (cmux's file pages, as a tab). The panel hides at the click and comes back once the
// view it opened is gone.
//
// A view counts as open while any of these differs from how the chat stood at the click: the
// header's lit tools (`headerState.lit`: Changes, Files and Preview while their split shows), the
// chat page's visibility (a tab in the chat's own pane hides it), or the chat's width (a split beside
// it narrows it). Once one of them changed and all are back, the panel returns. An open the host
// refused brings it back at once (`cancel`). The person's own toggle, the palette or a reveal ends the
// step aside too (SessionInfo.tsx `useSessionInfo`). Nothing polls: the header's state, the
// document's `visibilitychange` and a ResizeObserver on the chat say when something moved.
import { useCallback, useEffect, useRef, useState } from "react";

/// How much narrower the chat must get to count as a split beside it (a resize by hand is smaller).
const NARROWED_PX = 40;
/// How long it waits for the view it opened to show. Some opens change nothing it can see (a split
/// already open, a tab added to the right column, a document opened in another app): with no sign by
/// then, the panel comes back rather than stay hidden until the toggle.
export const STEP_ASIDE_SETTLE_MS = 2000;

type Stood = { lit: string; width: number; opened: boolean };

export type StepAside = {
  /// The panel is aside now.
  aside: boolean;
  /// A row opened something: hide until it is gone.
  step: () => void;
  /// Back now (the open failed, or the person asked for the panel).
  cancel: () => void;
};

export function useStepAside(lit: readonly string[], shell: HTMLElement | null | undefined): StepAside {
  const [aside, setAside] = useState(false);
  const stood = useRef<Stood | undefined>(undefined);
  const litKey = lit.join(" ");
  const litNow = useRef(litKey);
  litNow.current = litKey;
  const step = useCallback(() => {
    stood.current = { lit: litNow.current, width: shell?.clientWidth ?? 0, opened: false };
    setAside(true);
  }, [shell]);
  const cancel = useCallback(() => {
    stood.current = undefined;
    setAside(false);
  }, []);
  useEffect(() => {
    if (!aside) return;
    const check = () => {
      const at = stood.current;
      if (!at) return;
      const hidden = document.visibilityState === "hidden";
      const narrowed = !!shell && at.width > 0 && shell.clientWidth < at.width - NARROWED_PX;
      if (hidden || narrowed || litNow.current !== at.lit) at.opened = true;
      else if (at.opened) cancel();
    };
    check();
    // A bounded wait, not a sync: it ends early on any sign above, and only brings the panel back.
    const settle = setTimeout(() => {
      if (stood.current && !stood.current.opened) cancel();
    }, STEP_ASIDE_SETTLE_MS);
    document.addEventListener("visibilitychange", check);
    const resized = typeof ResizeObserver === "function" && shell ? new ResizeObserver(check) : undefined;
    if (resized && shell) resized.observe(shell);
    return () => {
      clearTimeout(settle);
      document.removeEventListener("visibilitychange", check);
      resized?.disconnect();
    };
    // `litKey`: the header's lit tools changing is one of the things that moved.
  }, [aside, shell, litKey, cancel]);
  return { aside, step, cancel };
}
