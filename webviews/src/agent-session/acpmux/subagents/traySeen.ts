// Whether the person could see the composer hat now: it is on screen (any part of it intersects the
// viewport), its page shows (`visibilityState`), and its window has focus (`document.hasFocus()`).
// The linger (trayLinger.ts) counts a finished line's grace only while this holds, so what ended
// while the person was in another window or app waits for them (Leo, 2026-11-08: "not remove it for
// a bit if the user recently looked at it").
//
// One IntersectionObserver on the hat's node and three listeners (the document's
// `visibilitychange`, the window's `focus` and `blur`) while the hat is mounted; all of them go when
// it unmounts, which also reports false. Each fires on a change only (a scroll into or out of view,
// a tab switch, a window switch), never per frame or per token. With no IntersectionObserver (a test
// DOM) the hat counts as on screen.
import { useEffect, useLayoutEffect, useRef, type RefObject } from "react";

/// Reports through `onSeen` whether `node`'s hat could be seen, on each change, and false when it
/// unmounts or stops drawing (`drawn` false). Reads `node` when the hat starts drawing (its root keeps
/// one node while it draws).
export function useTraySeen(
  node: RefObject<HTMLElement | null>,
  drawn: boolean,
  onSeen: ((seen: boolean) => void) | undefined,
): void {
  const report = useRef(onSeen);
  useLayoutEffect(() => {
    report.current = onSeen;
  });
  const reporting = onSeen !== undefined;
  useEffect(() => {
    const element = node.current;
    if (!reporting || !drawn || !element) return undefined;
    const doc = element.ownerDocument;
    const view = doc.defaultView;
    let onScreen = true;
    let last: boolean | undefined;
    const update = () => {
      const seen = onScreen && doc.visibilityState !== "hidden" && (doc.hasFocus?.() ?? true);
      if (seen === last) return;
      last = seen;
      report.current?.(seen);
    };
    const Observer = view?.IntersectionObserver;
    const observer = Observer
      ? new Observer((entries) => {
          const entry = entries.at(-1);
          if (!entry) return;
          onScreen = entry.isIntersecting;
          update();
        })
      : undefined;
    observer?.observe(element);
    doc.addEventListener("visibilitychange", update);
    view?.addEventListener("focus", update);
    view?.addEventListener("blur", update);
    update();
    return () => {
      observer?.disconnect();
      doc.removeEventListener("visibilitychange", update);
      view?.removeEventListener("focus", update);
      view?.removeEventListener("blur", update);
      report.current?.(false);
    };
  }, [node, drawn, reporting]);
}
