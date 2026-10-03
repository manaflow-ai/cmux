// Icons used by the conversation transcript, from the agent-pane reference prototype
// (src/conversation/icons.tsx). All draw in currentColor in a 16px box
// unless noted, matching the stroke weight of src/shell/icons.tsx.
import type { CSSProperties, ReactNode } from "react";

export type CvIconProps = {
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
};

function Svg({
  size = 16,
  box = 16,
  strokeWidth = 1.25,
  className,
  style,
  fill = "none",
  children,
}: CvIconProps & { box?: number; fill?: string; children: ReactNode }) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox={`0 0 ${box} ${box}`}
      fill={fill}
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export const ChevronRight = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M6.25 4.25 10 8l-3.75 3.75" />
  </Svg>
);

export const ChevronDown = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M4.25 6.25 8 10l3.75-3.75" />
  </Svg>
);

export const Globe = (p: CvIconProps) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="6" />
    <path d="M2 8h12M8 2c-2 2-2.6 4-2.6 6s.6 4 2.6 6M8 2c2 2 2.6 4 2.6 6s-.6 4-2.6 6" />
  </Svg>
);

export const Copy = (p: CvIconProps) => (
  <Svg {...p}>
    <rect x="5.25" y="5.25" width="8.25" height="8.25" rx="2" />
    <path d="M10.75 5.25V4.5a2 2 0 0 0-2-2H4.5a2 2 0 0 0-2 2v4.25a2 2 0 0 0 2 2h.75" />
  </Svg>
);

export const Pencil = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M10.6 3.1a1.6 1.6 0 0 1 2.3 2.3l-7.6 7.6-3 .7.7-3Z" />
    <path d="M9.5 4.2l2.3 2.3" />
  </Svg>
);

/** Four small rings in a 2x2 grid (grouped tool activity: "Used the browser and …"). */
export const ToolGroup = (p: CvIconProps) => (
  <Svg {...p}>
    <circle cx="4.75" cy="4.75" r="2.55" />
    <circle cx="11.25" cy="4.75" r="2.55" />
    <circle cx="4.75" cy="11.25" r="2.55" />
    <circle cx="11.25" cy="11.25" r="2.55" />
  </Svg>
);

/** Square with a plus over a minus ("Edited N files" card). */
export const DiffFile = (p: CvIconProps) => (
  <Svg {...p}>
    <rect x="2.75" y="2.75" width="10.5" height="10.5" rx="2.4" />
    <path d="M8 4.9v4M6 6.9h4M6 11h4" />
  </Svg>
);

export const Undo = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M5.5 3.25 3 5.75l2.5 2.5" />
    <path d="M3 5.75h6.25a3.75 3.75 0 0 1 0 7.5H7.5" />
  </Svg>
);

export const Lock = (p: CvIconProps) => (
  <Svg {...p}>
    <rect x="3.25" y="7" width="9.5" height="7" rx="2" />
    <path d="M5.25 7V5.25a2.75 2.75 0 0 1 5.5 0V7" />
    <circle cx="8" cy="10.5" r=".4" fill="currentColor" />
  </Svg>
);

export const ArrowDown = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M8 2.5v11M3.5 9 8 13.5 12.5 9" />
  </Svg>
);

export const Plus = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M8 2.25v11.5M2.25 8h11.5" />
  </Svg>
);

export const Check = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M4.2 8.3 6.8 10.9 11.8 5.2" />
  </Svg>
);

/** Thread summary toggle in the title bar: two rings with bars. */
export const SummaryToggle = (p: CvIconProps) => (
  <Svg {...p}>
    <circle cx="4.4" cy="4.6" r="1.9" />
    <circle cx="4.4" cy="11.4" r="1.9" />
    <path d="M8.6 4.6h5.1M8.6 11.4h5.1" />
  </Svg>
);

/** Two linked rings ("View all" sources). */
export const Connectors = (p: CvIconProps) => (
  <Svg {...p}>
    <circle cx="3.9" cy="12.1" r="1.7" />
    <circle cx="12.1" cy="3.9" r="1.7" />
    <path d="M5.4 11.1c1.5-.4 1.7-1.6 2.6-3.1s2.1-2.6 2.6-3.1" />
    <circle cx="8" cy="8" r="1.7" />
  </Svg>
);

export const GitHubMark = ({ size = 16, className, style }: CvIconProps) => (
  <svg
    className={className}
    style={style}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    fill="currentColor"
    aria-hidden="true"
  >
    <path d="M8 .2a8 8 0 0 0-2.53 15.6c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.71 1.22 1.87.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.83-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 8 .2Z" />
  </svg>
);

/** Open-ended ring used as the "working" spinner. */
export const Spinner = ({ size = 16, className, style, strokeWidth = 1.5 }: CvIconProps) => (
  <svg
    className={className}
    style={style}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    fill="none"
    aria-hidden="true"
  >
    <path d="M8 2.75a5.25 5.25 0 1 1-4.55 2.63" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" />
  </svg>
);

/** Stop square inside the send button while a turn runs (8.5px, #3a3b36). */
export const StopSquare = ({ size = 16, className, style }: CvIconProps) => (
  <svg
    className={className}
    style={{ color: "#3a3b36", ...style }}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    aria-hidden="true"
  >
    <rect x="3.75" y="3.5" width="8.5" height="9" rx="1.6" fill="currentColor" />
  </svg>
);

/** The composer's dim busy ring (12px) with a brighter leading arc. */
export const ComposerSpinner = ({ className, style }: CvIconProps) => (
  <svg className={className} style={style} width={12} height={12} viewBox="0 0 12 12" fill="none" aria-hidden="true">
    <circle cx="6" cy="6" r="5.1" stroke="#51524c" strokeWidth="1.5" />
    <path d="M6 .9a5.1 5.1 0 0 1 4.4 2.5" stroke="#7d7e78" strokeWidth="1.5" strokeLinecap="round" />
  </svg>
);

export const PlayTriangle = ({ size = 16, className, style }: CvIconProps) => (
  <svg
    className={className}
    style={{ color: "#3b3c37", ...style }}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    aria-hidden="true"
  >
    <path d="M4.7 4.1v7.8c0 .7.75 1.1 1.3.7l5.9-3.9a.8.8 0 0 0 0-1.4L6 3.4c-.55-.4-1.3 0-1.3.7Z" fill="currentColor" />
  </svg>
);

/** `</>` before a code card's language label. */
export const CodeBrackets = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M4.6 5.2 1.9 8l2.7 2.8M11.4 5.2 14.1 8l-2.7 2.8M9.1 4.6 6.9 11.4" />
  </Svg>
);

/** Code card "wrap lines" toggle. */
export const WrapLines = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M2.5 8.5h9M9 6l2.5 2.5L9 11M13.5 4.5v8" />
  </Svg>
);

/*
 * Turn action glyphs (copy, fork, anchor), drawn in one 84×24 strip measured from the
 * fixture captures. Each 28px button shows its third of the strip through the viewBox,
 * so the glyphs keep their measured sub-pixel positions.
 */
function TurnStrip({ slot }: { slot: 0 | 1 | 2 }) {
  return (
    <svg
      width={28}
      height={28}
      viewBox={`${slot * 28} -2 28 28`}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {slot === 0 && (
        <>
          <rect x={10.6} y={6.2} width={7.8} height={7.6} rx={2.1} />
          <rect x={7.1} y={9.4} width={7.9} height={7.6} rx={2.1} fill="var(--cx-main)" />
        </>
      )}
      {slot === 1 && <path d="M34.1 11.5h4.7l5.8-5.7M40.8 5.7h3.9v4M41.4 13.4l3.4 3.4M44.8 13.1v3.8h-3.9" />}
      {slot === 2 && (
        <>
          <circle cx={68.5} cy={7.4} r={1.15} />
          <path d="M68.5 8.6v8M63.2 12.1c0 2.6 2.4 4.5 5.3 4.5s5.3-1.9 5.3-4.5M62.3 13l.9-.9.9.9M72.9 13l.9-.9.9.9" />
        </>
      )}
    </svg>
  );
}
export const TurnCopy = () => <TurnStrip slot={0} />;
export const TurnFork = () => <TurnStrip slot={1} />;
export const TurnAnchor = () => <TurnStrip slot={2} />;

/** arXiv favicon shown before "Paper" citation links. */
export const ArxivMark = ({ size = 16, className, style }: CvIconProps) => (
  <svg className={className} style={style} width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
    <path d="M3.2 2.2 12.8 13.8" stroke="#b31b1b" strokeWidth="2.2" strokeLinecap="round" />
    <path d="M12.6 2.4 3.4 13.6" stroke="#9a9a96" strokeWidth="1.6" strokeLinecap="round" />
    <path d="M3.2 2.2 8 8" stroke="#d64b3c" strokeWidth="1.4" strokeLinecap="round" />
  </svg>
);

/** ⌘ glyph of computer-use / app tool rows ("Inspect the Atlas Fixtures window"). */
export const CommandKey = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <circle cx="4.5" cy="4.5" r="2.05" />
    <circle cx="11.5" cy="4.5" r="2.05" />
    <circle cx="4.5" cy="11.5" r="2.05" />
    <circle cx="11.5" cy="11.5" r="2.05" />
    <path d="M10 6 6 10" />
  </Svg>
);

/** Terminal square of shell tool rows ("Ran pwd && …"). */
export const TerminalSquare = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <rect x="2.25" y="2.25" width="11.5" height="11.5" rx="2.6" />
    <path d="M5.2 6.2 7 8 5.2 9.8M8.2 10h2.6" />
  </Svg>
);

/** Open book of file-read tool rows ("Read SKILL.md"). */
export const OpenBook = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <path d="M8 4.4c-1.4-1.1-3.3-1.4-5.5-1.1v9.4c2.2-.3 4.1 0 5.5 1.1 1.4-1.1 3.3-1.4 5.5-1.1V3.3c-2.2-.3-4.1 0-5.5 1.1ZM8 4.4v9.4M4.6 3.2v9.3" />
  </Svg>
);

/** Magnifier of file-search tool rows ("Searched for … in …"). */
export const Magnifier = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <circle cx="7" cy="7" r="4.25" />
    <path d="M10.2 10.2 13.5 13.5" />
  </Svg>
);

/** Folder of directory-listing tool rows ("Listed files in …"). */
export const Folder = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <path d="M2.25 4.75c0-.83.67-1.5 1.5-1.5h2.6l1.4 1.5h4.5c.83 0 1.5.67 1.5 1.5v5.5c0 .83-.67 1.5-1.5 1.5h-8.5c-.83 0-1.5-.67-1.5-1.5Z" />
  </Svg>
);

/** Page with folded corner: file links and file resources. */
export const FileDoc = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <path d="M4.25 2.25h5l3 3v8.5h-8Z" />
    <path d="M9.25 2.25v3h3" />
  </Svg>
);

/** Envelope of agent-to-agent message cards ("Coordinator · cmux-ci to leo"). */
export const Envelope = (p: CvIconProps) => (
  <Svg strokeWidth={1.1} {...p}>
    <rect x="2.25" y="3.75" width="11.5" height="8.5" rx="1.75" />
    <path d="m2.75 4.75 5.25 4 5.25-4" />
  </Svg>
);

/** Arrow between a message's sender and recipient. */
export const ArrowRight = (p: CvIconProps) => (
  <Svg {...p}>
    <path d="M3.5 8h9M9.25 4.75 12.5 8l-3.25 3.25" />
  </Svg>
);
