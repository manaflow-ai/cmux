// Icons for the rail menus (profile and explore).
import type { CSSProperties, ReactNode } from "react";
import "./menus.css";

type P = {
  size?: number;
  style?: CSSProperties;
  className?: string;
  children?: ReactNode;
  strokeWidth?: number;
};

function Svg({ size = 16, style, className, children, strokeWidth = 1.2 }: P) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={style}
      className={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

/** Person in a circle ("Logged in with API key"). */
export const IconAccount = (p: P) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="5.9" />
    <circle cx="8" cy="6.5" r="2" />
    <path d="M4.2 12.4c.9-1.4 2.2-2.1 3.8-2.1s2.9.7 3.8 2.1" />
  </Svg>
);

/** Egg with two eyes ("Show Mini"). */
export const IconMini = (p: P) => (
  <Svg {...p}>
    <path d="M8 1.9c2.6 0 4.9 3.5 4.9 6.6 0 3-2.1 5.4-4.9 5.4s-4.9-2.4-4.9-5.4C3.1 5.4 5.4 1.9 8 1.9Z" />
    <circle cx="6.9" cy="8.7" r="0.55" fill="currentColor" stroke="none" />
    <circle cx="9.1" cy="8.7" r="0.55" fill="currentColor" stroke="none" />
  </Svg>
);

/** Life buoy ("Help"). */
export const IconHelp = (p: P) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="5.9" />
    <circle cx="8" cy="8" r="2.6" />
    <path d="M3.9 3.9l2.3 2.3M12.1 3.9 9.8 6.2M3.9 12.1l2.3-2.3M12.1 12.1 9.8 9.8" />
  </Svg>
);

/** Door with arrow ("Log out"). */
export const IconLogOut = (p: P) => (
  <Svg {...p}>
    <path d="M6.2 2.3H4.1c-.9 0-1.5.6-1.5 1.5v8.4c0 .9.6 1.5 1.5 1.5h2.1" />
    <path d="M6.6 8h7M10.9 5.2 13.7 8l-2.8 2.8" />
  </Svg>
);

/** Filled push pin, tilted ("Unpin from sidebar"). */
export const IconPinFilled = (p: P) => (
  <svg
    width={p.size ?? 16}
    height={p.size ?? 16}
    viewBox="0 0 16 16"
    style={p.style}
    className={p.className}
    aria-hidden="true"
  >
    <path
      fill="currentColor"
      d="M9.4 1.9c.5-.5 1.3-.5 1.8 0l2.9 2.9c.5.5.5 1.3 0 1.8-.4.4-1 .5-1.5.3l-1.7 1.7.2 1.6c.1.6-.1 1.1-.5 1.5l-.4.4L4.4 6.3l.4-.4c.4-.4.9-.6 1.5-.5l1.6.2 1.7-1.7c-.2-.5-.1-1.1.3-1.5Z"
    />
    <path d="M6.6 9.4 2.6 13.4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
  </svg>
);

/* Composer menu icons (permissions and effort popovers), drawn at stroke 1.25. */

type ComposerIconProps = {
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
};

function ComposerSvg({
  size = 16,
  strokeWidth = 1.25,
  className,
  style,
  children,
}: ComposerIconProps & { children: ReactNode }) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

/** Counter-clockwise reset arrow (effort popover). */
export const IconReset = (p: ComposerIconProps) => (
  <ComposerSvg {...p}>
    <path d="M3.1 6.4A5.2 5.2 0 1 1 2.9 9.2" />
    <path d="M2.7 3.3v3.4h3.4" />
  </ComposerSvg>
);

/** Raised hand outline ("Ask for approval"). */
export const IconHand = (p: ComposerIconProps) => (
  <ComposerSvg {...p}>
    <path d="M5.4 8.6V3.9a1 1 0 0 1 2 0v3.6M7.4 7.2V2.8a1 1 0 0 1 2 0v4.4M9.4 7.2V3.6a1 1 0 0 1 2 0v4.6M11.4 8.2V5.6a1 1 0 0 1 2 0v3.6c0 2.9-2 4.9-4.6 4.9-1.6 0-2.8-.7-3.7-2L3 9.6a1 1 0 0 1 1.5-1.3l.9.9" />
  </ComposerSvg>
);

/** Rounded octagon with a prompt ("Approve for me"). */
export const IconTerminalShield = (p: ComposerIconProps) => (
  <ComposerSvg {...p}>
    <path d="M8 1.9 13.3 4.9v6.2L8 14.1 2.7 11.1V4.9Z" />
    <path d="M5.6 6.4 7.2 8 5.6 9.6M8.4 9.8h2" />
  </ComposerSvg>
);
