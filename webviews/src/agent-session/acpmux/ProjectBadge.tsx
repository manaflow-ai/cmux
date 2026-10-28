import { useState, type CSSProperties } from "react";
import type { Project } from "./ProjectChooser";
import { GLYPHS } from "./projectGlyphs";
import { useProjectIcon } from "./projectIcon";

/// A deliberately small visual cue derived only from the project identity we already have.
/// Remote projects keep the host/peer distinction visible; home and local folders stay quiet.
export type ProjectKind = "remote" | "home" | "local";

export function projectKind(project: Pick<Project, "cwd" | "peer" | "host">): ProjectKind {
  if (project.peer || project.host) return "remote";
  const cwd = project.cwd.trim();
  return cwd === "" || cwd === "/" || cwd === "~" ? "home" : "local";
}

/// The project's own icon when the host finds one on this Mac (projectIcon.ts: its GitHub owner's
/// avatar, else an icon file in the folder or its repository), else its framework's or language's
/// mark; an icon WebKit cannot draw falls back to the mark or a quiet monogram.
/// If there is no icon, use a quiet monogram with no tile; never repeat a generic folder tile.
export function ProjectBadge({ project }: { project: Project }) {
  const kind = projectKind(project);
  const icon = useProjectIcon(kind === "local" ? project.cwd : undefined);
  const [broken, setBroken] = useState<string | undefined>();
  const shown = icon.src && icon.src !== broken ? icon.src : undefined;
  const glyph = !shown && icon.glyph ? GLYPHS[icon.glyph] : undefined;
  return (
    <span
      className="acpmux-project-badge"
      style={glyph ? ({ "--acpmux-project-badge": glyph.color } as CSSProperties) : undefined}
      data-project-kind={kind}
      data-project-icon={shown ? "" : undefined}
      data-project-glyph={glyph ? icon.glyph : undefined}
      data-project-folder={!shown && !glyph ? "" : undefined}
      aria-hidden="true"
    >
      {shown ? (
        <img src={shown} alt="" draggable={false} onError={() => setBroken(shown)} />
      ) : glyph ? (
        <svg width={14} height={14} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
          <path fill="currentColor" d={glyph.path} />
        </svg>
      ) : (
        <MonogramMark value={project.label || project.cwd} />
      )}
    </span>
  );
}

/// The folder a project with no icon and no mark draws, in the muted text color (the trigger's own).
function MonogramMark({ value }: { value: string }) {
  const letter = Array.from(value.trim())[0]?.toUpperCase() ?? "•";
  return (
    <span className="acpmux-project-monogram" aria-hidden="true">
      {letter}
    </span>
  );
}
