// Line icons for the changes view and the edited-files card, after the Codex glyphs in
// manaflow-ai/codex-atlas-clone (src/changes/icons.tsx, src/conversation/icons.tsx).
// They draw in currentColor, so the pane's theme colors them.
import React, { useLayoutEffect, type SVGProps } from "react";
import { createFileTreeIconResolver, getBuiltInSpriteSheet } from "@pierre/trees";

type P = SVGProps<SVGSVGElement>;
const line = (size: number): P => ({
  width: size,
  height: size,
  viewBox: "0 0 16 16",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.25,
  strokeLinecap: "round",
  strokeLinejoin: "round",
  "aria-hidden": true,
});

export const ChevronDown = (p: P) => (
  <svg {...line(12)} {...p}>
    <path d="M4 6l4 4 4-4" />
  </svg>
);
export const Check = (p: P) => (
  <svg {...line(14)} {...p}>
    <path d="M3.5 8.5l3 3 6-7" />
  </svg>
);
export const ChevronLeft = (p: P) => (
  <svg {...line(16)} {...p}>
    <path d="M10 3.5L5.5 8l4.5 4.5" />
  </svg>
);
export const Wrap = (p: P) => (
  <svg {...line(16)} {...p}>
    <path d="M13 2.5v11" />
    <path d="M2.8 5.2h5.4a2.3 2.3 0 0 1 0 4.6H4.2" />
    <path d="M6 8l-1.9 1.8L6 11.6" />
  </svg>
);
export const CollapseAll = (p: P) => (
  <svg {...line(16)} {...p}>
    <path d="M5 1.8v4.6M3 4.6l2 1.9 2-1.9M5 14.2V9.6M3 11.4l2-1.9 2 1.9M9.4 6.4h4.4M9.4 9.6h3.2" />
  </svg>
);
/// Codex fills the split icon's halves red and green; here they take the diff colors.
export const SplitView = (p: P) => (
  <svg width={16} height={16} viewBox="0 0 16 16" aria-hidden {...p}>
    <rect x="1.6" y="2.1" width="12.8" height="11.8" rx="2.2" fill="none" stroke="currentColor" strokeWidth="1.25" />
    <rect x="3.2" y="3.7" width="4.4" height="8.6" rx="0.8" fill="var(--acpmux-del)" />
    <rect x="8.4" y="3.7" width="4.4" height="8.6" rx="0.8" fill="var(--acpmux-add)" />
  </svg>
);
export const Panels = (p: P) => (
  <svg {...line(16)} {...p}>
    <rect x="1.6" y="5.4" width="9.6" height="9" rx="2.2" />
    <path d="M4.8 5.3V4a2.2 2.2 0 0 1 2.2-2.2h5.4A2.2 2.2 0 0 1 14.6 4v5.2a2.2 2.2 0 0 1-2.2 2.2h-1.2" />
  </svg>
);
export const Eye = (p: P) => (
  <svg {...line(16)} {...p}>
    <path d="M1.6 8s2.3-4.4 6.4-4.4S14.4 8 14.4 8s-2.3 4.4-6.4 4.4S1.6 8 1.6 8z" />
    <circle cx="8" cy="8" r="2" />
  </svg>
);
export const More = (p: P) => (
  <svg width={16} height={16} viewBox="0 0 16 16" fill="currentColor" aria-hidden {...p}>
    <circle cx="3.5" cy="8" r="1.1" />
    <circle cx="8" cy="8" r="1.1" />
    <circle cx="12.5" cy="8" r="1.1" />
  </svg>
);
export const Search = (p: P) => (
  <svg {...line(16)} {...p}>
    <circle cx="7" cy="7" r="4.6" />
    <path d="M10.4 10.4l3.4 3.4" />
  </svg>
);
export const DiffFile = (p: P) => (
  <svg {...line(20)} strokeWidth={1.1} {...p}>
    <rect x="2.75" y="2.75" width="10.5" height="10.5" rx="2.4" />
    <path d="M8 4.9v4M6 6.9h4M6 11h4" />
  </svg>
);

const SPRITE_ID = "acpmux-file-icon-sprite";
/// The tree draws its sprite inside its own shadow root; headers in the page need a copy.
/// It is checked in the DOM rather than a flag, so a replaced body gets it again.
function ensureSprite() {
  if (typeof document === "undefined" || !document.body || document.getElementById(SPRITE_ID)) return;
  const holder = document.createElement("div");
  holder.id = SPRITE_ID;
  holder.hidden = true;
  holder.innerHTML = getBuiltInSpriteSheet("complete");
  document.body.prepend(holder);
}

// The tree's own resolver, so a header shows the same icon as the file's tree row.
const icons = createFileTreeIconResolver({ set: "complete", colored: true });

/// The file-type icon @pierre/trees shows for `path`, so diff headers and tree rows match.
export function FileTypeIcon({ path }: { path: string }) {
  useLayoutEffect(ensureSprite, []);
  const resolved = icons.resolveIcon("file-tree-icon-file", path).name;
  const id = resolved.startsWith("file-tree-builtin-") ? resolved : "file-tree-builtin-default";
  return (
    <svg
      className="acpmux-file-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      aria-hidden
      data-icon={id.slice("file-tree-builtin-".length)}
    >
      <use href={`#${id}`} />
    </svg>
  );
}
