import { useState, type CSSProperties, type ReactNode } from "react";
import type { Project } from "./ProjectChooser";
import { useProjectIcon, type ProjectGlyphName } from "./projectIcon";

const BADGE_COLORS = [
  "var(--agent-ansi-4, #58a6ff)",
  "var(--agent-ansi-5, #bf7af0)",
  "var(--agent-ansi-6, #f2c94c)",
  "var(--agent-ansi-2, #32d74b)",
  "var(--agent-ansi-3, #ff9f0a)",
] as const;

/// A deliberately small visual cue derived only from the project identity we already have.
/// Remote projects keep the host/peer distinction visible; home and local folders stay quiet.
export type ProjectKind = "remote" | "home" | "local";

export function projectKind(project: Pick<Project, "cwd" | "peer" | "host">): ProjectKind {
  if (project.peer || project.host) return "remote";
  const cwd = project.cwd.trim();
  return cwd === "" || cwd === "/" || cwd === "~" ? "home" : "local";
}

/// The letters and their color. Both come from the repository's name when the project has one, so
/// every worktree of a repository wears the same tile, and the color stays the same across launches.
function projectBadge(project: Project): { label: string; color: string } {
  const name = (project.repo?.name ?? project.label).trim();
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const label = (words.length > 1 ? words.map((word) => word[0]).join("") : name).slice(0, 2);
  let hash = 0;
  for (const character of name.toLowerCase()) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return { label: (label || "?").toUpperCase(), color: BADGE_COLORS[Math.abs(hash) % BADGE_COLORS.length]! };
}

/// The project's own icon when the host finds one on this Mac (projectIcon.ts: a file in the
/// folder or its repository, else the GitHub owner's avatar), else its language's glyph, else its
/// letters; an icon WebKit cannot draw falls back to the glyph or the letters too.
export function ProjectBadge({ project }: { project: Project }) {
  const badge = projectBadge(project);
  const kind = projectKind(project);
  const icon = useProjectIcon(kind === "local" ? project.cwd : undefined);
  const [broken, setBroken] = useState<string | undefined>();
  const shown = icon.src && icon.src !== broken ? icon.src : undefined;
  const glyph = !shown && icon.glyph ? GLYPHS[icon.glyph] : undefined;
  return (
    <span
      className="acpmux-project-badge"
      style={{ "--acpmux-project-badge": glyph?.color ?? badge.color } as CSSProperties}
      data-project-kind={kind}
      data-project-icon={shown ? "" : undefined}
      data-project-glyph={glyph ? icon.glyph : undefined}
      aria-hidden="true"
    >
      {shown ? (
        <img src={shown} alt="" draggable={false} onError={() => setBroken(shown)} />
      ) : glyph ? (
        <svg width={14} height={14} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
          {glyph.mark}
        </svg>
      ) : (
        badge.label
      )}
    </span>
  );
}

/// Each language's or framework's mark, drawn small in its own color on the tile (16-unit box).
const GLYPHS: Record<ProjectGlyphName, { color: string; mark: ReactNode }> = {
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
