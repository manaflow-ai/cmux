import type { Project } from "./ProjectChooser";

/// A deliberately small visual cue derived only from the project identity we already have.
/// Remote projects keep the host/peer distinction visible; home and local folders stay quiet.
export type ProjectKind = "remote" | "home" | "local";

export function projectKind(project: Pick<Project, "cwd" | "peer" | "host">): ProjectKind {
  if (project.peer || project.host) return "remote";
  const cwd = project.cwd.trim();
  return cwd === "" || cwd === "/" || cwd === "~" ? "home" : "local";
}
