import { isLive, type BackgroundGroup } from "./backgroundTasks";

/// How many finished tasks a group lists before Show more, and how many more each press adds.
export const FINISHED_PAGE = 8;

export type PanelSection = { id: "running" | "finished"; groups: BackgroundGroup[] };

/// The list under its two headings, as Claude Desktop's panel splits it: "Running N", then
/// "Finished N" (Leo, 2026-11-03, on its "Finished 28"). The groups keep their order
/// (backgroundTasks.ts: running first, oldest first; then ended, latest first); a group that still
/// runs a nested agent is a running one (`isLive`). An empty heading is left out.
export function panelSections(groups: readonly BackgroundGroup[]): PanelSection[] {
  const running = groups.filter(isLive);
  const ended = groups.filter((group) => !isLive(group));
  return [
    { id: "running" as const, groups: running },
    { id: "finished" as const, groups: ended },
  ].filter((section) => section.groups.length > 0);
}
