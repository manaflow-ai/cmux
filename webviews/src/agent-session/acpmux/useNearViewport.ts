// Lazy transcript content (videos, charts): true once an element comes within a screen of the
// viewport, so a long transcript loads and draws only what is near the reader. Where there is no
// IntersectionObserver it is true at once.
import { useEffect, useState } from "react";

/// Where an element is from the viewport: `near` once it came within a screen of it (and from then
/// on), `far` while the observer has said it is not, `unknown` before the observer's first answer.
/// A part that waits to draw until it is near is on its way to its height only while not `far`
/// (unsettledHeights.ts): one a screen or more away, or in a hidden pane, never draws there.
export type ViewportReach = "unknown" | "near" | "far";

export function useViewportReach(element: Element | null): ViewportReach {
  const [reach, setReach] = useState<ViewportReach>("unknown");
  const near = reach === "near";
  useEffect(() => {
    if (near || !element) return;
    if (typeof IntersectionObserver === "undefined") return setReach("near");
    const observer = new IntersectionObserver(
      (entries) => setReach(entries.some((entry) => entry.isIntersecting) ? "near" : "far"),
      { rootMargin: "100% 0px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [element, near]);
  return reach;
}

export function useNearViewport(element: Element | null): boolean {
  return useViewportReach(element) === "near";
}
