// Stroke glyphs for the five entry kinds, drawn for this page (no SF Symbols in web pages: Apple's
// license; coordinator Q5). 16-unit grid, `currentColor`.
import type { HistoryKind } from "./types";

const PATHS: Record<HistoryKind, string> = {
  // Globe: circle, equator, meridian.
  page: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM1.75 8h12.5M8 1.75c1.9 1.8 2.75 3.9 2.75 6.25S9.9 12.45 8 14.25C6.1 12.45 5.25 10.35 5.25 8S6.1 3.55 8 1.75Z",
  // Map pin.
  location:
    "M8 14.25s4.5-4.1 4.5-7.75a4.5 4.5 0 0 0-9 0c0 3.65 4.5 7.75 4.5 7.75ZM8 8.25a1.75 1.75 0 1 0 0-3.5 1.75 1.75 0 0 0 0 3.5Z",
  // U-turn arrow back.
  closed: "M5.5 3.25 2.75 6l2.75 2.75M2.75 6h6.5a4 4 0 0 1 0 8h-3",
  // Terminal: window with a prompt.
  command: "M2.25 2.75h11.5v10.5H2.25ZM4.75 6l2 2-2 2M8.25 10.25h3",
  // Four-point sparkle.
  agent:
    "M8 1.75c.45 3.1 1.65 4.3 4.75 4.75C9.65 6.95 8.45 8.15 8 11.25 7.55 8.15 6.35 6.95 3.25 6.5 6.35 6.05 7.55 4.85 8 1.75ZM12.5 10.5c.2 1.25.75 1.8 2 2-1.25.2-1.8.75-2 2-.2-1.25-.75-1.8-2-2 1.25-.2 1.8-.75 2-2Z",
};

export function KindIcon({ kind }: { kind: HistoryKind }) {
  return (
    <svg className="history-kind-icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={PATHS[kind]}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
