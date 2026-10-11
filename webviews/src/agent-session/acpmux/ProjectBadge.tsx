import type { CSSProperties } from "react";
import type { Project } from "./ProjectChooser";

const BADGE_COLORS = [
  "var(--agent-ansi-4, #58a6ff)",
  "var(--agent-ansi-5, #bf7af0)",
  "var(--agent-ansi-6, #f2c94c)",
  "var(--agent-ansi-2, #32d74b)",
  "var(--agent-ansi-3, #ff9f0a)",
] as const;

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

export function ProjectBadge({ project }: { project: Project }) {
  const badge = projectBadge(project);
  return (
    <span
      className="acpmux-project-badge"
      style={{ "--acpmux-project-badge": badge.color } as CSSProperties}
      aria-hidden="true"
    >
      {badge.label}
    </span>
  );
}
