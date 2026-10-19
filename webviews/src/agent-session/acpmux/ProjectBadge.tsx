import { useState, type CSSProperties } from "react";
import type { Project } from "./ProjectChooser";
import { experimentArm } from "../../experiments/experiment";
import { LazyLanguageIcon } from "./changes/LazyFileIcons";
import { LANGUAGE_ICONS } from "./changes/languageIcons";
import { fileIconColor, projectLanguageIcons } from "./fileIcons.experiment";
import { useProjectArt } from "./projectIcon";

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

function projectBadge(project: Project): { label: string; color: string } {
  const words = project.label
    .trim()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean);
  const label = (words.length > 1 ? words.map((word) => word[0]).join("") : project.label.trim()).slice(0, 2);
  let hash = 0;
  for (const character of project.cwd) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return { label: (label || "?").toUpperCase(), color: BADGE_COLORS[Math.abs(hash) % BADGE_COLORS.length]! };
}

/// The project's own favicon when the host finds one on this Mac (projectIcon.ts), else its
/// language's icon from its marker files, else its letters; an icon WebKit cannot draw falls back
/// to the letters too.
export function ProjectBadge({ project }: { project: Project }) {
  const badge = projectBadge(project);
  const kind = projectKind(project);
  const art = useProjectArt(kind === "local" ? project.cwd : undefined);
  const [broken, setBroken] = useState<string | undefined>();
  const shown = art.src && art.src !== broken ? art.src : undefined;
  const language =
    !shown && art.language && LANGUAGE_ICONS.has(art.language) && experimentArm(projectLanguageIcons) === "on"
      ? art.language
      : undefined;
  return (
    <span
      className="acpmux-project-badge"
      style={{ "--acpmux-project-badge": badge.color } as CSSProperties}
      data-project-kind={kind}
      data-project-icon={shown || language ? "" : undefined}
      data-project-language={language}
      data-icon-color={language ? experimentArm(fileIconColor) : undefined}
      aria-hidden="true"
    >
      {shown ? (
        <img src={shown} alt="" draggable={false} onError={() => setBroken(shown)} />
      ) : language ? (
        <LazyLanguageIcon language={language} fallback={badge.label} />
      ) : (
        badge.label
      )}
    </span>
  );
}
