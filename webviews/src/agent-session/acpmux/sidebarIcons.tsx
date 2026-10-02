// Session-row status glyphs, in the stroke style of the reference icon set
// (reference prototype src/shell/icons.tsx): 16px box, 1.25 stroke, currentColor.
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

/** A pending permission or question: the reference shield with an exclamation. */
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

/** Work in progress: the reference spinner arc, drawn still so an idle pane stays idle. */
export const WorkingIcon = () => (
  <Glyph>
    <path d="M8 2.75a5.25 5.25 0 1 1-4.55 2.63" strokeWidth={1.5} />
  </Glyph>
);

/** The rail's 18px glyphs, in the same stroke style. */
function RailGlyph({ children }: { children: ReactNode }) {
  return (
    <svg
      width={18}
      height={18}
      viewBox="0 0 18 18"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export const HomeIcon = () => (
  <RailGlyph>
    <path d="M3 8.2 9 3.2l6 5v6.3a1.3 1.3 0 0 1-1.3 1.3h-3.2v-4.3h-3v4.3H4.3A1.3 1.3 0 0 1 3 14.5Z" />
  </RailGlyph>
);

export const ChatsIcon = () => (
  <RailGlyph>
    <path d="M4.3 3.8h9.4a1.6 1.6 0 0 1 1.6 1.6v5.8a1.6 1.6 0 0 1-1.6 1.6H8.2L5 15.2v-2.4h-.7a1.6 1.6 0 0 1-1.6-1.6V5.4a1.6 1.6 0 0 1 1.6-1.6Z" />
  </RailGlyph>
);

export const ClockIcon = () => (
  <RailGlyph>
    <circle cx="9" cy="9" r="6.4" />
    <path d="M9 5.6V9l2.4 1.5" />
  </RailGlyph>
);

export const PullIcon = () => (
  <RailGlyph>
    <circle cx="5" cy="4.5" r="1.7" />
    <circle cx="5" cy="13.5" r="1.7" />
    <circle cx="13" cy="13.5" r="1.7" />
    <path d="M5 6.2v5.6M13 11.8V7.6a2 2 0 0 0-2-2H8.6M10.2 3.9 8.6 5.6l1.6 1.6" />
  </RailGlyph>
);

export const MoreIcon = () => (
  <RailGlyph>
    <circle cx="4.2" cy="9" r=".6" fill="currentColor" />
    <circle cx="9" cy="9" r=".6" fill="currentColor" />
    <circle cx="13.8" cy="9" r=".6" fill="currentColor" />
  </RailGlyph>
);

/** The pencil-on-square "New chat" glyph, list-sized. */
export const NewChatIcon = () => (
  <Glyph>
    <path d="M7.3 3H4.4A1.4 1.4 0 0 0 3 4.4v7.2A1.4 1.4 0 0 0 4.4 13h7.2a1.4 1.4 0 0 0 1.4-1.4V8.7" />
    <path d="M11.3 2.7a1.15 1.15 0 0 1 1.7 1.7L8.2 9.2 6 9.8l.6-2.2Z" />
  </Glyph>
);

/** A session on a cloud machine. */
export const CloudIcon = () => (
  <Glyph>
    <path d="M4.6 12.25h7a2.65 2.65 0 0 0 .35-5.28A4 4 0 0 0 4.3 6.3a3 3 0 0 0 .3 5.95Z" />
  </Glyph>
);

/** A session on a branch: the reference branch glyph. */
export const BranchIcon = () => (
  <Glyph>
    <circle cx="5" cy="3.75" r="1.5" />
    <circle cx="5" cy="12.25" r="1.5" />
    <circle cx="11" cy="5.5" r="1.5" />
    <path d="M5 5.25v5.5M11 7c0 2.4-2 3.1-6 3.75" />
  </Glyph>
);

/** A session in its own git worktree: a folder with a branch fork. */
export const WorktreeIcon = () => (
  <Glyph>
    <path d="M2.5 4.5c0-.6.4-1 1-1h2.6l1.4 1.5h5c.6 0 1 .4 1 1v5.5c0 .6-.4 1-1 1h-9c-.6 0-1-.4-1-1Z" />
    <path d="M7 7.5v3M7 9c1.6 0 2.5-.5 2.5-1.5" />
  </Glyph>
);

/** The search field's magnifier. */
export const SearchIcon = () => (
  <Glyph>
    <circle cx="7" cy="7" r="4.25" />
    <path d="m10.25 10.25 3 3" />
  </Glyph>
);
