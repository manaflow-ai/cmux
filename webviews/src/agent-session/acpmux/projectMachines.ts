import type { Project } from "./ProjectChooser";

/// A chooser row's key: the folder's path, and its machine's id before it for another machine's folder.
export const rowKey = (project: Project) => (project.peer ? `${project.peer}\u0000${project.cwd}` : project.cwd);

/// The chooser's folders with each machine's together: this Mac's first when it has any, then each
/// other machine in the order its first folder came. Within a machine the order is kept.
export function byMachine<T extends { peer?: string }>(projects: T[]): T[] {
  const machines = new Map<string, T[]>();
  for (const project of projects) {
    const id = project.peer ?? "";
    const rows = machines.get(id);
    if (rows) rows.push(project);
    else machines.set(id, [project]);
  }
  if (machines.size < 2) return projects;
  const local = machines.get("") ?? [];
  machines.delete("");
  return [...local, ...[...machines.values()].flat()];
}

/// Row key → the machine whose heading goes over that row: the first folder of each machine, except
/// a list that is only this Mac's.
export function machineHeadings(shown: readonly Project[]): Map<string, { peer?: string; host?: string }> {
  const headings = new Map<string, { peer?: string; host?: string }>();
  if (!shown.some((project) => project.peer)) return headings;
  let previous: string | null = null;
  for (const project of shown) {
    const id = project.peer ?? "";
    if (id !== previous) headings.set(rowKey(project), { peer: project.peer, host: project.host });
    previous = id;
  }
  return headings;
}
