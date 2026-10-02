// Inline SVG icons for the Codex chrome. Every icon draws in `currentColor`, so
// set `color` on the icon or its parent. `size` is the CSS box (default per icon);
// the drawing keeps the stroke widths measured from the reference at that size.
import type { CSSProperties, ReactNode } from "react";

export type IconProps = {
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
  color?: string;
};

function Svg({
  size = 16,
  box = 16,
  strokeWidth = 1.25,
  className,
  style,
  color,
  fill = "none",
  children,
}: IconProps & { box?: number; fill?: string; children: ReactNode }) {
  return (
    <svg
      className={className}
      style={color ? { color, ...style } : style}
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

/** Closed scalloped outline (the Codex logo / gear silhouette). */
export function lobedPath(
  cx: number,
  cy: number,
  notchR: number,
  peakR: number,
  lobes: number,
  phaseDeg: number,
) {
  const step = (2 * Math.PI) / lobes;
  const phase = (phaseDeg * Math.PI) / 180;
  const pt = (a: number, r: number) => [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  // Circle through notch_i, peak (mid angle), notch_{i+1}: radius from chord + sagitta.
  const chord = 2 * notchR * Math.sin(step / 2);
  const sagitta = peakR - notchR * Math.cos(step / 2);
  const arcR = (chord * chord) / 4 / (2 * sagitta) + sagitta / 2;
  let d = "";
  for (let i = 0; i < lobes; i++) {
    const a0 = phase + i * step;
    const a1 = a0 + step;
    const [x0, y0] = pt(a0, notchR);
    const [x1, y1] = pt(a1, notchR);
    if (i === 0) d += `M${x0.toFixed(3)} ${y0.toFixed(3)}`;
    d += `A${arcR.toFixed(3)} ${arcR.toFixed(3)} 0 ${sagitta > arcR ? 1 : 0} 1 ${x1.toFixed(3)} ${y1.toFixed(3)}`;
  }
  return d + "Z";
}

/* ---------- Title bar ---------- */

export const IconArrowLeft = (p: IconProps) => (
  <Svg {...p}>
    <path d="M13.6 8H2.4M7.3 3.1 2.4 8l4.9 4.9" />
  </Svg>
);

export const IconArrowRight = (p: IconProps) => (
  <Svg {...p}>
    <path d="M2.4 8h11.2M8.7 3.1 13.6 8l-4.9 4.9" />
  </Svg>
);

export const IconSidebar = (p: IconProps) => (
  <Svg {...p}>
    <rect x="2.125" y="2.625" width="11.75" height="10.75" rx="2.6" />
    <path d="M6 2.75v10.5" />
  </Svg>
);

export const IconNewTab = (p: IconProps) => (
  <Svg {...p}>
    <rect x="2.125" y="2.625" width="11.75" height="10.75" rx="2.6" />
    <path d="M8 5.6v4.8M5.6 8h4.8" />
  </Svg>
);

export const IconMore = (p: IconProps) => (
  <Svg {...p} fill="currentColor" strokeWidth={0}>
    <circle cx="3" cy="8" r="1.25" />
    <circle cx="8" cy="8" r="1.25" />
    <circle cx="13" cy="8" r="1.25" />
  </Svg>
);

export const IconClose = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4 4l8 8M12 4l-8 8" />
  </Svg>
);

export const IconPlus = (p: IconProps) => (
  <Svg {...p}>
    <path d="M8 2.75v10.5M2.75 8h10.5" />
  </Svg>
);

/* ---------- Icon rail (20px box, 1.5px stroke) ---------- */

export const IconHome = (p: IconProps) => (
  <Svg box={20} size={20} {...p} fill="currentColor" strokeWidth={0}>
    <path d="M9.35 2.75a1.05 1.05 0 0 1 1.3 0l7.05 5.6c.5.4.22 1.2-.42 1.2H17.2v6.35c0 .6-.45 1.1-1.05 1.1H12.1v-2.9a2.1 2.1 0 0 0-4.2 0V17H3.85c-.6 0-1.05-.5-1.05-1.1V9.55H2.72c-.64 0-.92-.8-.42-1.2Z" />
  </Svg>
);

export const IconClock = (p: IconProps) => (
  <Svg box={20} size={20} strokeWidth={1.5} {...p}>
    <circle cx="10" cy="10" r="7.75" />
    <path d="M10.3 5.6v4.5l-1.6 2.5" />
  </Svg>
);

export const IconPlugins = (p: IconProps) => (
  <Svg box={20} size={20} strokeWidth={1.5} {...p}>
    <path d="M17.75 10a7.75 7.75 0 1 0-3.4 6.4" />
    <path d="M17.75 10c0 1.6-.9 2.6-2.1 2.6-1.1 0-1.8-.8-1.8-2" />
    <path d="M8.2 9.3l2.6 2.6M10.4 8.2l1.2-1.2M12.1 9.9l1.2-1.2M8.4 13.3l-1 1" />
    <path d="M9.6 7.6l3.1 3.1c.3.3.3.7 0 1l-.6.6a2.4 2.4 0 0 1-3.4 0l-.5-.5a2.4 2.4 0 0 1 0-3.4l.6-.6c.2-.3.6-.3.8-.2Z" />
  </Svg>
);

export const IconDots = (p: IconProps) => (
  <Svg box={20} size={20} {...p} fill="currentColor" strokeWidth={0}>
    <circle cx="4" cy="10" r="1.5" />
    <circle cx="10" cy="10" r="1.5" />
    <circle cx="16" cy="10" r="1.5" />
  </Svg>
);

export const IconCodeReview = (p: IconProps) => (
  <Svg box={20} size={20} strokeWidth={1.5} {...p}>
    <circle cx="5.2" cy="5.1" r="1.8" />
    <circle cx="5.2" cy="14.9" r="1.8" />
    <circle cx="14.8" cy="14.9" r="1.8" />
    <path d="M5.2 6.9v6.2M14.8 13.1V8.1a2.9 2.9 0 0 0-2.9-2.9h-.9M12.6 3.3l-1.9 1.9 1.9 1.9" />
  </Svg>
);

export const IconGear = (p: IconProps) => (
  <Svg box={20} size={20} strokeWidth={1.5} {...p}>
    <path d={lobedPath(10, 10, 6.1, 7.7, 6, -60)} />
    <circle cx="10" cy="10" r="2.35" />
  </Svg>
);

/* ---------- Sidebar ---------- */

export const IconChevronDown = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4.6 6.3 8 9.6l3.4-3.3" />
  </Svg>
);

export const IconChevronRight = (p: IconProps) => (
  <Svg {...p}>
    <path d="M6.3 4.4 9.7 8l-3.4 3.6" />
  </Svg>
);

export const IconCheck = (p: IconProps) => (
  <Svg {...p}>
    <path d="M3 8.6 6.3 12 13 4.5" />
  </Svg>
);

export const IconBell = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4.5 5.9a3.5 3.5 0 0 1 7 0c0 2.7.8 4.1 1.5 4.9.3.3.1.8-.3.8H3.3c-.4 0-.6-.5-.3-.8.7-.8 1.5-2.2 1.5-4.9Z" />
    <path d="M6.5 14.4h3" />
  </Svg>
);

export const IconSearch = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="7.2" cy="7.2" r="4.6" />
    <path d="m10.6 10.6 3 3" />
  </Svg>
);

export const IconCompose = (p: IconProps) => (
  <Svg {...p}>
    <path d="M7.4 2.6H4.6a2 2 0 0 0-2 2v6.8a2 2 0 0 0 2 2h6.8a2 2 0 0 0 2-2V8.6" />
    <path d="M11.9 2.2a1.35 1.35 0 0 1 1.9 1.9L8.6 9.3l-2.4.5.5-2.4Z" />
  </Svg>
);

export const IconFolderOpen = (p: IconProps) => (
  <Svg {...p}>
    <path d="M1.4 11.7V4.3c0-.7.5-1.2 1.2-1.2h2.9l1.4 1.5h4.6c.7 0 1.2.5 1.2 1.2v.9" />
    <path d="M1.5 12.3 3.3 7.6c.2-.5.6-.8 1.1-.8h9.5c.6 0 1 .6.8 1.1l-1.6 4.4c-.2.5-.6.7-1.1.7H2.4c-.5 0-.9-.3-.9-.7Z" />
  </Svg>
);

export const IconFolder = (p: IconProps) => (
  <Svg {...p}>
    <path d="M2.3 4.1c0-.8.6-1.4 1.4-1.4h2.4c.4 0 .7.2 1 .4l1 1h4.2c.8 0 1.4.6 1.4 1.4v6.2c0 .8-.6 1.4-1.4 1.4H3.7c-.8 0-1.4-.6-1.4-1.4Z" />
    <path d="M2.3 6.7h11.4" />
  </Svg>
);

export const IconLaptop = (p: IconProps) => (
  <Svg {...p}>
    <rect x="2.6" y="3.2" width="10.8" height="7.6" rx="1.2" />
    <path d="M1.3 12.7h13.4" />
  </Svg>
);

export const IconBranch = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="4.1" cy="3.6" r="1.45" />
    <circle cx="4.1" cy="12.4" r="1.45" />
    <circle cx="11.9" cy="3.6" r="1.45" />
    <path d="M4.1 5.1v5.8M11.9 5.1c0 3.3-3.2 3.6-5.6 4.4-1.2.4-1.9 1-2.1 1.5" />
  </Svg>
);

export const IconShieldAlert = (p: IconProps) => (
  <Svg {...p}>
    <path d="M8 1.9 13 3.7v4.1c0 3.1-2.3 5.3-5 6.3-2.7-1-5-3.2-5-6.3V3.7Z" />
    <path d="M8 5.2v3.3" />
    <circle cx="8" cy="10.9" r=".35" fill="currentColor" />
  </Svg>
);

export const IconArrowUp = (p: IconProps) => (
  <Svg {...p}>
    <path d="M8 13.4V2.8M3.4 7.3 8 2.7l4.6 4.6" />
  </Svg>
);

/** Push pin tilted 45°, the hovered sidebar row's "Pin chat" button. 12px, 1px stroke. */
export const IconPin = ({ size = 12, strokeWidth = 2, ...p }: IconProps) => (
  <Svg {...p} box={24} size={size} strokeWidth={strokeWidth}>
    <g transform="rotate(45 12 12)">
      <path d="M12 17v5M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" />
    </g>
  </Svg>
);

/** Archive box (lid + body + slot), the hovered sidebar row's "Archive chat" button. 12px. */
export const IconArchive = ({ size = 12, strokeWidth = 1, ...p }: IconProps) => (
  <Svg {...p} box={12} size={size} strokeWidth={strokeWidth}>
    <rect x="1" y="1.3" width="10" height="2.9" rx="0.9" />
    <path d="M1.9 4.2v4.9c0 .8.6 1.4 1.4 1.4h5.4c.8 0 1.4-.6 1.4-1.4V4.2M4.9 6.6h2.2" />
  </Svg>
);

/* ---------- Split title bar and right pane ---------- */

/** Two bullets + lines (title bar "Tasks" toggle). */
export const IconChecklist = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="4" cy="4.4" r="1.75" />
    <circle cx="4" cy="11.6" r="1.75" />
    <path d="M8.2 4.4h5.6M8.2 11.6h5.6" />
  </Svg>
);

/** Diagonal expand corners (title bar, right edge, with a pane open). */
export const IconExpand = (p: IconProps) => (
  <Svg {...p}>
    <path d="M9.6 3.6h2.8v2.8M6.4 12.4H3.6V9.6" />
  </Svg>
);

/** Rect with a centre divider (right pane toggle). */
export const IconSplit = (p: IconProps) => (
  <Svg {...p}>
    <rect x="1.9" y="2.6" width="12.2" height="10.8" rx="2.6" />
    <path d="M8 2.75v10.5" />
  </Svg>
);

/** Square with plus over minus (Changes tab and tool). */
export const IconDiff = (p: IconProps) => (
  <Svg {...p}>
    <rect x="2.4" y="2.4" width="11.2" height="11.2" rx="2.4" />
    <path d="M8 4.9v4M6 6.9h4M6 11h4" />
  </Svg>
);

/** Globe (browser "New tab" tab). */
export const IconGlobe = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="6.1" />
    <path d="M1.9 8h12.2M8 1.9c-1.7 1.8-2.5 3.8-2.5 6.1s.8 4.3 2.5 6.1M8 1.9c1.7 1.8 2.5 3.8 2.5 6.1s-.8 4.3-2.5 6.1" />
  </Svg>
);

/** Dot + square bullets with lines (title bar inspector toggle). */
export const IconListDetail = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="3.8" cy="4.5" r="1.5" />
    <path d="M2.3 10h3v3h-3zM8 4.5h6M8 11.5h6" />
  </Svg>
);

export const IconTerminal = (p: IconProps) => (
  <Svg {...p}>
    <rect x="2.4" y="2.4" width="11.2" height="11.2" rx="2.4" />
    <path d="M5.4 6.2 7.2 8 5.4 9.8M8.6 10h2" />
  </Svg>
);

/** Chat bubble with a plus (Side chat). */
export const IconSideChat = (p: IconProps) => (
  <Svg {...p}>
    <path d="M8 2.2a5.8 5.8 0 1 1-2.9 10.8l-2.6.8.8-2.5A5.8 5.8 0 0 1 8 2.2Z" />
    <path d="M8 5.6v4.8M5.6 8h4.8" />
  </Svg>
);

/** Two overlapping folders (Files). */
export const IconFiles = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4.2 5.2V4a1.2 1.2 0 0 1 1.2-1.2h2.2l1.2 1.2h3.6A1.2 1.2 0 0 1 13.6 5.2v5.4a1.2 1.2 0 0 1-1.2 1.2h-.6" />
    <path d="M2.2 7.2A1.2 1.2 0 0 1 3.4 6h2.2l1.2 1.2h3.6a1.2 1.2 0 0 1 1.2 1.2v4.4a1.2 1.2 0 0 1-1.2 1.2H3.4a1.2 1.2 0 0 1-1.2-1.2Z" />
  </Svg>
);

/** Speech bubble (browser "Ask about this page"). */
export const IconChatBubble = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4.4 2.6h7.2a2 2 0 0 1 2 2v4.6a2 2 0 0 1-2 2H8.2l-3 2.4v-2.4h-.8a2 2 0 0 1-2-2V4.6a2 2 0 0 1 2-2Z" />
  </Svg>
);

/** Two chasing arrows (browser reload). */
export const IconRefresh = (p: IconProps) => (
  <Svg {...p}>
    <path d="M2.8 7.2A5.3 5.3 0 0 1 12.4 4.6M13.2 8.8A5.3 5.3 0 0 1 3.6 11.4" />
    <path d="M12.6 1.9v2.9H9.7M3.4 14.1v-2.9h2.9" />
  </Svg>
);

/* ---------- Brand ---------- */

/** Codex empty-state mark: scalloped outline with a terminal prompt. 48px default. */
export const CodexLogo = ({
  size = 48,
  strokeWidth = 2.85,
  className,
  style,
  color,
}: IconProps) => (
  <Svg
    box={48}
    size={size}
    strokeWidth={strokeWidth}
    className={className}
    style={style}
    color={color}
  >
    <path d={lobedPath(24, 24, 19.2, 22.7, 6, -135)} />
    <path d="M12.35 17.35 16.75 23.75l-4.3 6.5M25.35 30.35h9" strokeWidth={strokeWidth + 0.15} />
  </Svg>
);
