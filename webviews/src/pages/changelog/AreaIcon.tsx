import type { ReleaseArea } from "./types";

// Small stroke glyphs, not font characters, matching the page's text color.
const paths: Record<ReleaseArea, string> = {
  "agent-chat": "M2 2h12v9H7l-4 3v-3H2Z M5 5h6 M5 8h4",
  browser: "M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13Z M1.5 8h13 M8 1.5c-4 4-4 9 0 13 M8 1.5c4 4 4 9 0 13",
  sidebar: "M2 2h12v12H2Z M6 2v12 M3.5 5h1 M3.5 8h1",
  terminal: "M2 2h12v12H2Z M4.5 5l3 3-3 3 M9 11h3",
  workspaces: "M1.5 2h6v5h-6Z M9 2h5.5v5H9Z M1.5 9h6v5h-6Z M9 9h5.5v5H9Z",
  settings: "M2 4h12 M2 8h12 M2 12h12 M5 2v4 M10 6v4 M6 10v4",
  updates: "M13.5 5A6 6 0 0 0 2 6 M13.5 1.5V5H10 M2.5 11A6 6 0 0 0 14 10 M2.5 14.5V11H6",
  general: "M3 1.5h10v13H3Z M5.5 5h5 M5.5 8h5 M5.5 11h3",
};

export function AreaIcon({ area }: { area: ReleaseArea }) {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d={paths[area]}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
