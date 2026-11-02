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
/// mark, else a plain folder; an icon WebKit cannot draw falls back to the mark or the folder too.
/// Never letters and never a corner dot (Leo 2026-10-21: "do the icons/favicons/heuristics for icons
/// apply here yet?"; no dots on the rows).
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
        <FolderMark />
      )}
    </span>
  );
}

/// The folder a project with no icon and no mark draws, in the muted text color (the trigger's own).
function FolderMark() {
  return (
    <svg
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M1.9 4.6c0-.8.6-1.4 1.4-1.4h2.6l1.5 1.6h5.3c.8 0 1.4.6 1.4 1.4v5.6c0 .8-.6 1.4-1.4 1.4H3.3c-.8 0-1.4-.6-1.4-1.4Z" />
    </svg>
  );
}
