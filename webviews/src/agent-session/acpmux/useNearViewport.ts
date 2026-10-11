// Lazy transcript content (videos, charts): true once an element comes within a screen of the
// viewport, so a long transcript loads and draws only what is near the reader. Where there is no
// IntersectionObserver it is true at once.
import { useEffect, useState } from "react";

export function useNearViewport(element: Element | null): boolean {
  const [near, setNear] = useState(false);
  useEffect(() => {
    if (near || !element) return;
    if (typeof IntersectionObserver === "undefined") return setNear(true);
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) setNear(true);
      },
      { rootMargin: "100% 0px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [element, near]);
  return near;
}
