import type { ReactNode } from "react";
import "./scrollEdge.css";

/// Shared CSS-only edge treatment for sticky headers and scroll boundaries. It deliberately has no
/// scroll listener: the sticky element and its masked pseudo-element supply the short blur/fade band.
export function ScrollEdge({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={["ui-scroll-edge-fade", className].filter(Boolean).join(" ")}>{children}</div>;
}
