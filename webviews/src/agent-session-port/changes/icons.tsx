// Line icons for the Changes pane chrome, drawn to match the Codex glyphs at 2x.
// File-type icons come from @pierre/trees' built-in sprite (see FileTypeIcon).
import type { SVGProps } from "react";

type P = SVGProps<SVGSVGElement>;
const base = (size: number): P => ({
  width: size,
  height: size,
  viewBox: "0 0 16 16",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.25,
  strokeLinecap: "round",
  strokeLinejoin: "round",
});

export const ChevronDown = (p: P) => (
  <svg {...base(12)} {...p}>
    <path d="M4 6l4 4 4-4" />
  </svg>
);

export const ChevronRight = (p: P) => (
  <svg {...base(12)} {...p}>
    <path d="M6 4l4 4-4 4" />
  </svg>
);

export const ArrowRight = (p: P) => (
  <svg {...base(12)} {...p}>
    <path d="M3 8h10M9 4l4 4-4 4" />
  </svg>
);

export const Dots = (p: P) => (
  <svg {...base(16)} {...p} stroke="none" fill="currentColor">
    <circle cx="3" cy="8" r="1.15" />
    <circle cx="8" cy="8" r="1.15" />
    <circle cx="13" cy="8" r="1.15" />
  </svg>
);

export const FileSearch = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M8.5 14.5H5A2 2 0 0 1 3 12.5v-9A2 2 0 0 1 5 1.5h4.2L13 5.3v3" />
    <path d="M9 1.7V4a1.6 1.6 0 0 0 1.6 1.6H13" />
    <circle cx="11" cy="11.5" r="2.1" />
    <path d="M12.6 13.1l1.6 1.6" />
  </svg>
);

export const Refresh = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M2.8 7.2A5.3 5.3 0 0 1 12.4 4.6M13.2 8.8A5.3 5.3 0 0 1 3.6 11.4" />
    <path d="M12.6 1.9v2.9H9.7M3.4 14.1v-2.9h2.9" />
  </svg>
);

export const Wrap = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M13 2.5v11" />
    <path d="M2.8 5.2h5.4a2.3 2.3 0 0 1 0 4.6H4.2" />
    <path d="M6 8l-1.9 1.8L6 11.6" />
  </svg>
);

export const CollapseAll = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M5 1.8v4.6M3 4.6l2 1.9 2-1.9M5 14.2V9.6M3 11.4l2-1.9 2 1.9M9.4 6.4h4.4M9.4 9.6h3.2" />
  </svg>
);

export const SplitView = (p: P) => (
  <svg width={16} height={16} viewBox="0 0 16 16" {...p}>
    <rect x="1.6" y="2.1" width="12.8" height="11.8" rx="2.2" fill="none" stroke="currentColor" strokeWidth="1.25" />
    <rect x="3.2" y="3.7" width="9.6" height="3.9" rx="0.8" fill="#b3424f" />
    <rect x="3.2" y="8.4" width="9.6" height="3.9" rx="0.8" fill="#3f9a4d" />
  </svg>
);

export const Panels = (p: P) => (
  <svg {...base(16)} {...p}>
    <rect x="1.6" y="5.4" width="9.6" height="9" rx="2.2" />
    <path d="M4.8 5.3V4a2.2 2.2 0 0 1 2.2-2.2h5.4A2.2 2.2 0 0 1 14.6 4v5.2a2.2 2.2 0 0 1-2.2 2.2h-1.2" />
  </svg>
);

export const AlertCircle = (p: P) => (
  <svg {...base(16)} {...p}>
    <circle cx="8" cy="8" r="6.4" />
    <path d="M8 4.7v4" />
    <circle cx="8" cy="11.1" r=".35" fill="currentColor" />
  </svg>
);

export const Eye = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M1.6 8s2.3-4.4 6.4-4.4S14.4 8 14.4 8s-2.3 4.4-6.4 4.4S1.6 8 1.6 8z" />
    <circle cx="8" cy="8" r="2" />
  </svg>
);

export const OpenTab = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M7 3H4.6A1.6 1.6 0 0 0 3 4.6v6.8A1.6 1.6 0 0 0 4.6 13h6.8a1.6 1.6 0 0 0 1.6-1.6V9" />
    <path d="M9.5 3H13v3.5M13 3L8 8" />
  </svg>
);

export const CodeIcon = (p: P) => (
  <svg {...base(16)} {...p} strokeWidth={1.45}>
    <path d="M4.6 5.2L2.2 8l2.4 2.8M11.4 5.2L13.8 8l-2.4 2.8M9 4.9L7 11.1" />
  </svg>
);

export const Search = (p: P) => (
  <svg {...base(16)} {...p}>
    <circle cx="7" cy="7" r="4.6" />
    <path d="M10.4 10.4l3.4 3.4" />
  </svg>
);

export const Check = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M3 8.5l3.2 3.2L13.2 4.6" />
  </svg>
);

/** In-progress ring (refresh while loading): a faint track with a brighter 3/4 arc. */
export const Spinner = (p: P) => (
  <svg {...base(16)} {...p}>
    <circle cx="8" cy="8" r="5.25" opacity="0.3" />
    <path d="M8 2.75a5.25 5.25 0 1 1-5.25 5.25" />
  </svg>
);

/* Options menu (toolbar ⋯) row icons, changes-options.png. */
export const FileOutline = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M9.2 1.8H4.6A1.8 1.8 0 0 0 2.8 3.6v8.8a1.8 1.8 0 0 0 1.8 1.8h6.8a1.8 1.8 0 0 0 1.8-1.8V5z" />
  </svg>
);
export const ImageOutline = (p: P) => (
  <svg {...base(16)} {...p}>
    <rect x="1.9" y="2.4" width="12.2" height="11.2" rx="2" />
    <circle cx="10.2" cy="6" r="1.2" />
    <path d="M2.2 11.6l3.4-3.3 4.4 4.9" />
  </svg>
);
export const PlusMinusBox = (p: P) => (
  <svg {...base(16)} {...p}>
    <rect x="2.1" y="2.1" width="11.8" height="11.8" rx="2" />
    <path d="M8 4.6v4M6 6.6h4M6 11h4" />
  </svg>
);
export const Cube = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M8 1.6l5.6 3.2v6.4L8 14.4l-5.6-3.2V4.8z" />
    <path d="M2.6 4.9L8 8l5.4-3.1M8 8v6.2" />
  </svg>
);
export const Clipboard = (p: P) => (
  <svg {...base(16)} {...p}>
    <rect x="3" y="2.6" width="10" height="11.8" rx="2" />
    <path d="M6 2.6V2.2c0-.4.3-.6.6-.6h2.8c.3 0 .6.2.6.6v.4" />
  </svg>
);
export const EyeOutline = (p: P) => (
  <svg {...base(16)} {...p}>
    <path d="M1.2 8s2.5-4.6 6.8-4.6S14.8 8 14.8 8s-2.5 4.6-6.8 4.6S1.2 8 1.2 8z" />
    <circle cx="8" cy="8" r="2.1" />
  </svg>
);
