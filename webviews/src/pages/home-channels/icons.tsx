// The channels Home's own stroke icons (20 px grid, 1.5 px stroke, currentColor): the composer's
// format toolbar and bar, and the message hover card. Drawn for this page; no third-party glyphs.
import type { ReactNode } from "react";

export type HomeIconName =
  | "bold"
  | "italic"
  | "strike"
  | "link"
  | "orderedList"
  | "bulletList"
  | "quote"
  | "code"
  | "codeBlock"
  | "format"
  | "emoji"
  | "mention"
  | "send"
  | "reply"
  | "addReaction"
  | "more"
  | "close"
  | "chevronRight"
  | "plus"
  | "search"
  | "check"
  | "threads"
  | "hash"
  | "command";

const PATHS: Record<HomeIconName, ReactNode> = {
  bold: <path d="M6 4h5a3 3 0 0 1 0 6H6zM6 10h6a3 3 0 0 1 0 6H6z" strokeWidth="2" />,
  italic: <path d="M12 4H8.5M11.5 16H8M11 4l-2 12" />,
  strike: (
    <path d="M4 10h12M13.5 6.5c-.4-1.5-1.8-2.5-3.6-2.5-2 0-3.4 1.1-3.4 2.6 0 .9.4 1.6 1.3 2M6.5 13.5c.4 1.5 1.8 2.5 3.6 2.5 2 0 3.5-1.1 3.5-2.7 0-.6-.2-1.1-.6-1.6" />
  ),
  link: (
    <path d="M8.5 11.5a3 3 0 0 0 4.2 0l2.4-2.4a3 3 0 0 0-4.2-4.2l-.9.9M11.5 8.5a3 3 0 0 0-4.2 0l-2.4 2.4a3 3 0 0 0 4.2 4.2l.9-.9" />
  ),
  orderedList: (
    <path d="M9 5.5h7M9 10h7M9 14.5h7M4 4.5l1-.5v3.5M4 7.5h2M4 12.2c.3-.4.7-.7 1.1-.7.6 0 1 .4 1 .9 0 .8-2.1 1.6-2.1 2.6h2.1" />
  ),
  bulletList: (
    <>
      <path d="M8.5 5.5H16M8.5 10H16M8.5 14.5H16" />
      <circle cx="5" cy="5.5" r=".9" fill="currentColor" stroke="none" />
      <circle cx="5" cy="10" r=".9" fill="currentColor" stroke="none" />
      <circle cx="5" cy="14.5" r=".9" fill="currentColor" stroke="none" />
    </>
  ),
  quote: <path d="M5 4.5v11M8.5 5.5H16M8.5 10H16M8.5 14.5h5" />,
  code: <path d="M7 6l-4 4 4 4M13 6l4 4-4 4M11 5l-2 10" />,
  codeBlock: (
    <>
      <rect x="3" y="3.5" width="14" height="13" rx="2.5" />
      <path d="M8 8.5 6 10.5l2 2M12 8.5l2 2-2 2" />
    </>
  ),
  format: (
    <>
      <path d="M3 14.5 6.5 5l3.5 9.5M4.3 11h4.4M15.5 9v5.5M15.5 10.4c-.4-.9-1.2-1.4-2.1-1.4-1.3 0-2.2 1-2.2 2.75s.9 2.75 2.2 2.75c.9 0 1.7-.5 2.1-1.4" />
      <path d="M3 17h14" strokeWidth="1.2" />
    </>
  ),
  emoji: (
    <>
      <circle cx="10" cy="10" r="7" />
      <path d="M7 11.5c.7 1.2 1.8 1.8 3 1.8s2.3-.6 3-1.8" />
      <circle cx="7.6" cy="8.2" r=".9" fill="currentColor" stroke="none" />
      <circle cx="12.4" cy="8.2" r=".9" fill="currentColor" stroke="none" />
    </>
  ),
  mention: (
    <path d="M13 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0zm0 0v1.2c0 1 .7 1.8 1.7 1.8s1.8-.9 1.8-2.4A6.5 6.5 0 1 0 14 15.5" />
  ),
  send: <path d="M4 10 3 3.8 17 10 3 16.2zm0 0h6" strokeLinejoin="round" />,
  reply: (
    <path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h9A1.5 1.5 0 0 1 16 5.5v6a1.5 1.5 0 0 1-1.5 1.5H9l-3.5 3v-3h0A1.5 1.5 0 0 1 4 11.5zM7.5 7.5h5M7.5 10h3" />
  ),
  addReaction: (
    <>
      <path d="M16.3 9.2A6.5 6.5 0 1 1 10.8 3.6" />
      <path d="M7 11.5c.7 1.1 1.7 1.7 2.9 1.7s2.2-.6 2.9-1.7M15 2.5v5M12.5 5h5" />
      <circle cx="7.5" cy="8.3" r=".85" fill="currentColor" stroke="none" />
      <circle cx="12" cy="8.3" r=".85" fill="currentColor" stroke="none" />
    </>
  ),
  more: (
    <>
      <circle cx="10" cy="4.5" r="1.2" fill="currentColor" stroke="none" />
      <circle cx="10" cy="10" r="1.2" fill="currentColor" stroke="none" />
      <circle cx="10" cy="15.5" r="1.2" fill="currentColor" stroke="none" />
    </>
  ),
  close: <path d="M5 5l10 10M15 5 5 15" />,
  chevronRight: <path d="m8 5 5 5-5 5" />,
  plus: <path d="M10 4.5v11M4.5 10h11" />,
  search: (
    <>
      <circle cx="9" cy="9" r="5" />
      <path d="m12.8 12.8 3.7 3.7" />
    </>
  ),
  check: <path d="m5 10.5 3.2 3L15 6.5" />,
  threads: <path d="M4 5h12M4 10h12M4 15h7" />,
  hash: <path d="M8 3.5 6.5 16.5M13.5 3.5 12 16.5M4 7.5h12.5M3.5 12.5H16" />,
  command: (
    <path d="M7.5 7.5h5v5h-5zM7.5 7.5V6a1.5 1.5 0 1 0-1.5 1.5zM12.5 7.5V6A1.5 1.5 0 1 1 14 7.5zM7.5 12.5V14A1.5 1.5 0 1 1 6 12.5zM12.5 12.5V14a1.5 1.5 0 1 0 1.5-1.5z" />
  ),
};

export function HomeIcon({ name, size = 20 }: { name: HomeIconName; size?: number }) {
  return (
    <svg
      className="hc-icon"
      width={size}
      height={size}
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {PATHS[name]}
    </svg>
  );
}
