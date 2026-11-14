import { isLive, type BackgroundGroup, type BackgroundTask } from "./backgroundTasks";

/// How many finished tasks a group lists before Show more, and how many more each press adds.
export const FINISHED_PAGE = 8;

export type PanelSection = {
  id: "running" | "finished";
  groups: BackgroundGroup[];
  /// The chat's own commands, each a card of its own at the heading's level (no "This chat" block
  /// around them), as Claude Desktop's panel lists its shells: the running ones under Running, the
  /// ended ones under Finished (Leo, 2026-11-07).
  commands: BackgroundTask[];
};

/// The list under its two headings, as Claude Desktop's panel splits it: "Running N", then
/// "Finished N" (Leo, 2026-11-03, on its "Finished 28"). The groups keep their order
/// (backgroundTasks.ts: running first, oldest first; then ended, latest first); a group that still
/// runs a nested agent is a running one (`isLive`). The chat's own commands (the `commands` group)
/// split by their own state instead. N counts what the heading lists. An empty heading is left out.
export function panelSections(groups: readonly BackgroundGroup[]): PanelSection[] {
  const agents = groups.filter((group) => group.kind !== "commands");
  const own = groups.filter((group) => group.kind === "commands");
  return [
    { id: "running" as const, groups: agents.filter(isLive), commands: own.flatMap((group) => group.running) },
    {
      id: "finished" as const,
      groups: agents.filter((group) => !isLive(group)),
      commands: own.flatMap((group) => group.finished),
    },
  ].filter((section) => section.groups.length + section.commands.length > 0);
}
