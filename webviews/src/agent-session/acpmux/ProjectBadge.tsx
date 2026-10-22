import { useState, type CSSProperties } from "react";
import type { Project } from "./ProjectChooser";
import { GLYPHS } from "./projectGlyphs";
import { useProjectIcon } from "./projectIcon";

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
