// Inline SVG icons for the SF Symbol names the schema uses, plus the page's own glyphs.
// Stroke icons in currentColor, 16 x 16.
import type { ReactNode } from "react";

const paths: Record<string, ReactNode> = {
  gearshape: (
    <>
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1" />
      <circle cx="8" cy="8" r="4.6" />
    </>
  ),
  paintbrush: (
    <path d="M13.5 2.5 7 9l-1.8-.2L5 7l6.5-6.5M5 9.2c-1.6 0-2.6 1-2.6 2.6 0 .9-.4 1.6-1 1.9 2.8.7 5.2-.3 5.2-2.9" />
  ),
  terminal: (
    <>
      <rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2" />
      <path d="m4.5 6.2 2 1.8-2 1.8M8 10h3.2" />
    </>
  ),
  globe: (
    <>
      <circle cx="8" cy="8" r="6.2" />
      <path d="M1.8 8h12.4M8 1.8c-2.2 2.4-2.2 10 0 12.4M8 1.8c2.2 2.4 2.2 10 0 12.4" />
    </>
  ),
  house: <path d="M2.4 7.4 8 2.6l5.6 4.8M3.8 6.2v7.2h3V10h2.4v3.4h3V6.2" />,
  keyboard: (
    <>
      <rect x="1.4" y="3.6" width="13.2" height="8.8" rx="1.6" />
      <path d="M4 6.4h.01M6.7 6.4h.01M9.3 6.4h.01M12 6.4h.01M4 9.6h8" />
    </>
  ),
  bell: <path d="M4 11V7.2a4 4 0 0 1 8 0V11l1.2 1.2H2.8L4 11ZM6.5 13.6a1.6 1.6 0 0 0 3 0" />,
  "person.crop.circle": (
    <>
      <circle cx="8" cy="8" r="6.2" />
      <circle cx="8" cy="6.6" r="2.1" />
      <path d="M3.9 12.5c.9-1.5 2.4-2.3 4.1-2.3s3.2.8 4.1 2.3" />
    </>
  ),
  "square.stack": (
    <>
      <rect x="3.2" y="5" width="9.6" height="8.6" rx="1.6" />
      <path d="M4.8 3.2h6.4M6.2 1.6h3.6" />
    </>
  ),
  "server.rack": (
    <>
      <rect x="2" y="2.4" width="12" height="4.6" rx="1.2" />
      <rect x="2" y="9" width="12" height="4.6" rx="1.2" />
      <path d="M4.4 4.7h.01M4.4 11.3h.01" />
    </>
  ),
  // The code editor category (Settings > Code Editor).
  "chevron.left.forwardslash.chevron.right": (
    <path d="M5.2 4.4 1.8 8l3.4 3.6M10.8 4.4 14.2 8l-3.4 3.6M9.2 2.8 6.8 13.2" />
  ),
  curlybraces: (
    <path d="M5.6 2.2c-1.6 0-2 .7-2 2v1.4c0 1-.5 1.9-1.6 2.4 1.1.5 1.6 1.4 1.6 2.4v1.4c0 1.3.4 2 2 2M10.4 2.2c1.6 0 2 .7 2 2v1.4c0 1 .5 1.9 1.6 2.4-1.1.5-1.6 1.4-1.6 2.4v1.4c0 1.3-.4 2-2 2" />
  ),
  paintpalette: (
    <>
      <path d="M8 1.8a6.2 6.2 0 1 0 0 12.4c.9 0 1.4-.6 1.4-1.3 0-.8-.6-1.1-.6-1.8 0-.7.5-1.2 1.2-1.2h1.5a2.7 2.7 0 0 0 2.7-2.7C14.2 4.3 11.4 1.8 8 1.8Z" />
      <path d="M4.6 7.4h.01M6.2 4.6h.01M9.6 4.4h.01M11.6 6.8h.01" />
    </>
  ),
  sparkles: (
    <path d="M6.4 2.2 7.5 5.5 10.8 6.6 7.5 7.7 6.4 11 5.3 7.7 2 6.6 5.3 5.5 6.4 2.2ZM11.8 9.4l.6 1.7 1.7.6-1.7.6-.6 1.7-.6-1.7-1.7-.6 1.7-.6.6-1.7Z" />
  ),
  crown: <path d="M2.6 11.4 2 4.6l3.4 2.6L8 2.8l2.6 4.4L14 4.6l-.6 6.8H2.6ZM2.8 13.6h10.4" />,
  "hand.raised": (
    <path d="M5.4 8.6V3.4a1 1 0 0 1 2 0v4.2M7.4 7.2V2.6a1 1 0 0 1 2 0v4.6M9.4 7.4V3.6a1 1 0 0 1 2 0v5.2M11.4 8.4V6a1 1 0 0 1 2 0v3.6a5 5 0 0 1-5 4.8c-1.6 0-2.7-.6-3.6-1.7L2.6 10a1 1 0 0 1 1.5-1.3l1.3 1.2" />
  ),
  laptopcomputer: (
    <>
      <rect x="3" y="3.2" width="10" height="7.2" rx="1.2" />
      <path d="M1.4 12.8h13.2" />
    </>
  ),
  hammer: (
    <path d="M9.6 2.2 13.8 6.4l-1.6 1.6-1-1-6.6 6.6a1.2 1.2 0 0 1-1.7 0l-.5-.5a1.2 1.2 0 0 1 0-1.7L9 4.8l-1-1 1.6-1.6Z" />
  ),
  flask: <path d="M6.2 1.8h3.6M6.8 1.8v4.4L2.9 12.6a1 1 0 0 0 .9 1.6h8.4a1 1 0 0 0 .9-1.6L9.2 6.2V1.8M4.6 9.8h6.8" />,
  filter: <path d="M2.4 3.4h11.2L9.4 8.4v4.4l-2.8-1.4v-3L2.4 3.4Z" />,
  layers: <path d="M8 2.4 14 5.6 8 8.8 2 5.6 8 2.4ZM2 8.4l6 3.2 6-3.2M2 11l6 3.2 6-3.2" />,
  check: <path d="m3.6 8.4 2.8 2.8 6-6.4" />,
  lock: (
    <>
      <rect x="3.2" y="7" width="9.6" height="6.8" rx="1.4" />
      <path d="M5.4 7V5a2.6 2.6 0 0 1 5.2 0v2" />
    </>
  ),
  warning: <path d="M8 2.2 14.2 13H1.8L8 2.2ZM8 6.4v3.2M8 11.4h.01" />,
  update: <path d="M8 11.2V4.8M5.4 7.4 8 4.8l2.6 2.6M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4Z" />,
  reset: <path d="M3.2 6.2A5 5 0 1 1 3 9.4M3 2.8v3.6h3.6" />,
  play: <path d="M5 3.2v9.6L12.6 8 5 3.2Z" />,
  undo: <path d="M5.8 3.6 2.6 6.8l3.2 3.2M2.8 6.8h6.8a3.4 3.4 0 0 1 0 6.8H7.6" />,
  redo: <path d="m10.2 3.6 3.2 3.2-3.2 3.2M13.2 6.8H6.4a3.4 3.4 0 0 0 0 6.8h2" />,
  search: (
    <>
      <circle cx="7" cy="7" r="4.4" />
      <path d="m10.3 10.3 3.6 3.6" />
    </>
  ),
  "icloud.and.arrow.down": (
    <path d="M4.6 12.6h6.9a2.7 2.7 0 0 0 .4-5.4 4 4 0 0 0-7.7-.9 3.2 3.2 0 0 0 .4 6.3ZM8 6.8v4M6.5 9.4 8 10.9l1.5-1.5" />
  ),
  // Settings > Import: a tray with an arrow into it.
  "square.and.arrow.down": (
    <>
      <path d="M5.4 5.8H4.3a1 1 0 0 0-1 1v5.9a1 1 0 0 0 1 1h7.4a1 1 0 0 0 1-1V6.8a1 1 0 0 0-1-1h-1.1" />
      <path d="M8 1.8v7.4M5.8 7.2 8 9.4l2.2-2.2" />
    </>
  ),
  // Settings > Mobile: a phone with its top island.
  iphone: (
    <>
      <rect x="4.2" y="1.6" width="7.6" height="12.8" rx="1.8" />
      <path d="M7.1 3.6h1.8" />
    </>
  ),
  chevron: <path d="m4.5 6.2 3.5 3.6 3.5-3.6" />,
  pawprint: (
    <>
      <path d="M8 8.6c-2 0-3.4 1.7-3.4 3.2 0 1 .8 1.6 1.7 1.6.7 0 1.1-.4 1.7-.4s1 .4 1.7.4c.9 0 1.7-.6 1.7-1.6 0-1.5-1.4-3.2-3.4-3.2Z" />
      <circle cx="3.9" cy="6.9" r="1.1" />
      <circle cx="6.4" cy="4.3" r="1.1" />
      <circle cx="9.6" cy="4.3" r="1.1" />
      <circle cx="12.1" cy="6.9" r="1.1" />
    </>
  ),
  "square.and.pencil": (
    <>
      <path d="M7.2 3.5H4.3a1 1 0 0 0-1 1v7.2a1 1 0 0 0 1 1h7.2a1 1 0 0 0 1-1V8.8" />
      <path d="m11.3 2.7 2 2-5.6 5.6-2.4.4.4-2.4Z" />
    </>
  ),
  xmark: <path d="m4.5 4.5 7 7M11.5 4.5l-7 7" />,
  "contextualmenu.and.cursorarrow": (
    <>
      <rect x="1.6" y="1.8" width="9.4" height="8.6" rx="1.6" />
      <path d="M3.8 4.6h5M3.8 7.6h3.4M10 9.4l4.2 1.6-1.8.7-.7 1.8L10 9.4Z" />
    </>
  ),
  "arrow.turn.down.right": <path d="M3.5 3v4.6a2.4 2.4 0 0 0 2.4 2.4h7M10 7l3 3-3 3" />,
  grip: <path d="M6 4h.01M10 4h.01M6 8h.01M10 8h.01M6 12h.01M10 12h.01" />,
  "eye.slash": (
    <path d="M2.6 2.6l10.8 10.8M6.4 4.1A6.4 6.4 0 0 1 8 3.9c3.3 0 5.6 3.1 6 4.1-.2.5-.8 1.5-1.8 2.4M4 5.3C2.9 6.2 2.2 7.4 2 8c.4 1 2.7 4.1 6 4.1 1 0 1.9-.3 2.7-.7M6.7 6.8a1.8 1.8 0 0 0 2.5 2.5" />
  ),
  eye: (
    <>
      <path d="M2 8c.4-1 2.7-4.1 6-4.1S13.6 7 14 8c-.4 1-2.7 4.1-6 4.1S2.4 9 2 8Z" />
      <circle cx="8" cy="8" r="1.8" />
    </>
  ),
  "arrow.up.to.line": <path d="M3.4 2.6h9.2M8 13.4V5.4M4.8 8.4 8 5.2l3.2 3.2" />,
  "arrow.down.to.more": <path d="M8 2.6v7.6M4.8 7.2 8 10.4l3.2-3.2M4 13.4h.01M8 13.4h.01M12 13.4h.01" />,
};

export function Icon({ name, className }: { name: string; className?: string }) {
  return (
    <svg
      className={className ? `icon ${className}` : "icon"}
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name] ?? paths.gearshape}
    </svg>
  );
}

export function hasIcon(name: string): boolean {
  return name in paths;
}
