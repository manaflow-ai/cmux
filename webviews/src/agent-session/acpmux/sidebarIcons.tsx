// Session-row status glyphs, in the stroke style of the atlas icon set
// (codex-atlas-clone src/shell/icons.tsx): 16px box, 1.25 stroke, currentColor.
import type { ReactNode } from "react";

function Glyph({ children, size = 16 }: { children: ReactNode; size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

/** A pending permission or question: the atlas shield with an exclamation. */
export const NeedsInputIcon = () => (
  <Glyph>
    <path d="M8 1.9 13 3.7v4.1c0 3.1-2.3 5.3-5 6.3-2.7-1-5-3.2-5-6.3V3.7Z" />
    <path d="M8 5.2v3.3" />
    <circle cx="8" cy="10.9" r=".35" fill="currentColor" />
  </Glyph>
);

/** A lost agent: a circled exclamation. */
export const DisconnectedIcon = () => (
  <Glyph>
    <circle cx="8" cy="8" r="5.6" />
    <path d="M8 5.2v3.3" />
    <circle cx="8" cy="10.8" r=".35" fill="currentColor" />
  </Glyph>
);

/** Work in progress: the atlas spinner arc, drawn still so an idle pane stays idle. */
export const WorkingIcon = () => (
  <Glyph>
    <path d="M8 2.75a5.25 5.25 0 1 1-4.55 2.63" strokeWidth={1.5} />
  </Glyph>
);
