// Prototype glyphs in the reference stroke style: 16px box, 1.25 stroke, currentColor.
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

/** An agent session: a four-point spark, the one kind drawn in full text colour. */
export const AgentIcon = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M8 2.25c.35 2.6 1.15 3.4 3.75 3.75C9.15 6.35 8.35 7.15 8 9.75 7.65 7.15 6.85 6.35 4.25 6 6.85 5.65 7.65 4.85 8 2.25Z" />
    <path d="M12 10.25c.15 1 .5 1.35 1.5 1.5-1 .15-1.35.5-1.5 1.5-.15-1-.5-1.35-1.5-1.5 1-.15 1.35-.5 1.5-1.5Z" />
  </Glyph>
);

export const TerminalIcon = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <rect x="2.25" y="3" width="11.5" height="10" rx="2" />
    <path d="m5 6.5 2 1.5-2 1.5M8.5 10H11" />
  </Glyph>
);

export const BrowserIcon = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <circle cx="8" cy="8" r="5.75" />
    <path d="M2.25 8h11.5M8 2.25c1.6 1.6 2.4 3.5 2.4 5.75S9.6 12.15 8 13.75C6.4 12.15 5.6 10.25 5.6 8S6.4 3.85 8 2.25Z" />
  </Glyph>
);

/** The workspace stack. */
export const StackIcon = () => (
  <Glyph size={18}>
    <path d="M8 2.5 13.5 5 8 7.5 2.5 5Z" />
    <path d="m2.5 8 5.5 2.5L13.5 8M2.5 11l5.5 2.5 5.5-2.5" />
  </Glyph>
);

/** History: a clock with a back arrow, like a browser's. */
export const HistoryIcon = () => (
  <Glyph size={18}>
    <path d="M2.9 6.2A5.5 5.5 0 1 1 2.5 8" />
    <path d="M2.5 3.5v2.75h2.75M8 5.25V8l2 1.25" />
  </Glyph>
);

export const PlusIcon = () => (
  <Glyph size={18}>
    <path d="M8 3.25v9.5M3.25 8h9.5" />
  </Glyph>
);

export const CloseIcon = () => (
  <Glyph>
    <path d="m4.5 4.5 7 7M11.5 4.5l-7 7" />
  </Glyph>
);

/** Promote the mini window into a workspace tab: a box with an arrow into it. */
export const PromoteIcon = () => (
  <Glyph size={14}>
    <path d="M9.5 2.75h3.75v3.75M13.25 2.75 8 8" />
    <path d="M12.75 9.5v2.25a1.5 1.5 0 0 1-1.5 1.5h-7a1.5 1.5 0 0 1-1.5-1.5v-7a1.5 1.5 0 0 1 1.5-1.5H6.5" />
  </Glyph>
);

/** Row detail settings: three sliders. */
export const SlidersIcon = () => (
  <Glyph>
    <path d="M3 4.5h10M3 8h10M3 11.5h10" />
    <circle cx="10" cy="4.5" r="1.4" fill="var(--agent-page-bg, Canvas)" />
    <circle cx="5.5" cy="8" r="1.4" fill="var(--agent-page-bg, Canvas)" />
    <circle cx="9" cy="11.5" r="1.4" fill="var(--agent-page-bg, Canvas)" />
  </Glyph>
);

/** A pull request, row-detail sized. */
export const PullRequestIcon = ({ size = 12 }: { size?: number }) => (
  <Glyph size={size}>
    <circle cx="4.5" cy="3.75" r="1.5" />
    <circle cx="4.5" cy="12.25" r="1.5" />
    <circle cx="11.5" cy="12.25" r="1.5" />
    <path d="M4.5 5.25v5.5M11.5 10.75V6.5a2 2 0 0 0-2-2H7.5M9 3 7.5 4.5 9 6" />
  </Glyph>
);

/** A branch, row-detail sized. */
export const BranchIcon = ({ size = 12 }: { size?: number }) => (
  <Glyph size={size}>
    <circle cx="5" cy="3.75" r="1.5" />
    <circle cx="5" cy="12.25" r="1.5" />
    <circle cx="11" cy="5.5" r="1.5" />
    <path d="M5 5.25v5.5M11 7c0 2.4-2 3.1-6 3.75" />
  </Glyph>
);
