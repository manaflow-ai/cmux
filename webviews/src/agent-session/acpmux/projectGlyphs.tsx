import type { ReactNode } from "react";
import type { ProjectGlyphName } from "./projectIcon";

/// Each language's or framework's mark, drawn small in its own color on the tile (16-unit box).
/// The colors are the languages' brand colors, content rather than chrome, so the system-blue
/// ratchet skips this catalog.
export const GLYPHS: Record<ProjectGlyphName, { color: string; mark: ReactNode }> = {
  swift: {
    color: "#f05138",
    mark: (
      <path
        fill="currentColor"
        d="M13.4 10.3c.9-2.8-.5-6-3.3-8.1 1.3 1.9 1.9 4.2 1.4 6C9.3 6.5 6.8 4.7 4.6 2.8c1.2 1.6 2.5 3.1 3.9 4.5C6.5 6 4.4 4.6 2.4 3.1c1.9 2.6 4.3 5 7 7-2.3 1.4-5.2 1.3-8 .1 1.9 2 4.5 3.4 7.4 3.4 1.7 0 2.7-.7 3.6-.7.8 0 1.4.5 1.6.9.3-1.3-.4-2.8-.6-3.5Z"
      />
    ),
  },
  rust: {
    color: "#ce7e4f",
    mark: (
      <g fill="none" stroke="currentColor">
        <circle cx="8" cy="8" r="6" strokeWidth="2.2" strokeDasharray="1.6 1.54" />
        <circle cx="8" cy="8" r="3.6" strokeWidth="1.6" />
      </g>
    ),
  },
  react: {
    color: "#3fb6d8",
    mark: (
      <g fill="none" stroke="currentColor" strokeWidth="1.1">
        <ellipse cx="8" cy="8" rx="7" ry="2.7" />
        <ellipse cx="8" cy="8" rx="7" ry="2.7" transform="rotate(60 8 8)" />
        <ellipse cx="8" cy="8" rx="7" ry="2.7" transform="rotate(120 8 8)" />
        <circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none" />
      </g>
    ),
  },
  typescript: {
    color: "#3178c6",
    mark: (
      <g fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
        <path d="M1.5 5.5h5.5M4.25 5.5v7" />
        <path d="M14 6.2c-.4-.6-1.1-.9-1.9-.9-1.1 0-1.9.6-1.9 1.5 0 2 3.9 1.3 3.9 3.5 0 1-.9 1.7-2.1 1.7-.9 0-1.7-.4-2.1-1" />
      </g>
    ),
  },
  node: {
    color: "#5fa04e",
    mark: (
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinejoin="round"
        d="M8 1.5 13.6 4.75v6.5L8 14.5 2.4 11.25v-6.5Z"
      />
    ),
  },
  python: {
    color: "#3776ab",
    mark: (
      <g>
        <path
          fill="currentColor"
          d="M7.9 1.2c-3 0-2.9 1.3-2.9 1.3V4h3v.6H3.8S1.5 4.4 1.5 7.9s2 3.4 2 3.4H5V9.6s-.1-2 2-2h3.1s1.9 0 1.9-1.8V3.1s.3-1.9-4.1-1.9Zm-1.6 1a.6.6 0 1 1 0 1.2.6.6 0 0 1 0-1.2Z"
        />
        <path
          fill="#f2c94c"
          d="M8.1 14.8c3 0 2.9-1.3 2.9-1.3V12H8v-.6h4.2s2.3.2 2.3-3.3-2-3.4-2-3.4H11v1.7s.1 2-2 2H5.9s-1.9 0-1.9 1.8v2.7s-.3 1.9 4.1 1.9Zm1.6-1a.6.6 0 1 1 0-1.2.6.6 0 0 1 0 1.2Z"
        />
      </g>
    ),
  },
  go: {
    color: "#00add8",
    mark: (
      <g fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
        <path d="M7 5.6A2.9 2.9 0 1 0 7.4 9.4V8.2H5.6" />
        <circle cx="11.6" cy="8" r="2.6" />
      </g>
    ),
  },
  ruby: {
    color: "#cc342d",
    mark: (
      <g fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
        <path d="M4.5 2.5h7L14.5 6 8 13.8 1.5 6Z" />
        <path d="M1.5 6h13M5.6 6 8 13.8 10.4 6 8 2.5 5.6 6" />
      </g>
    ),
  },
};
