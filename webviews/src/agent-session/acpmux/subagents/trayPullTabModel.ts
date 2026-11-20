import { setTrayTucked } from "../chatDisplay";
import { subagentStatus } from "../summary/subagentStatusListModel";
import type { TrayItem } from "./runningTray";
import { asksPerson } from "./trayAttention";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

/// The tab's count as it reads: its control is sized for two digits, so a hundred or more reads "99+".
export const pullTabCountText = (running: number): string => (running > 99 ? "99+" : String(running));

/// What the tucked tab flags: the lines that wait on the person (counted as the hat's header counts
/// them, trayHeadKinds.ts) and the ones that run. A chat queued for a run slot waits on cmux, not on
/// the person: it counts with what runs, never as a dot (trayAttention.ts asksPerson).
export function pullTabCounts(
  items: readonly TrayItem[],
  waiting: ReadonlySet<string>,
): { waiting: number; running: number } {
  let waits = 0;
  for (const item of items)
    if (
      item.kind === "agent"
        ? subagentStatus(item.agent, waiting) === "waiting"
        : item.kind === "session" && asksPerson(item.session)
    )
      waits += 1;
  return { waiting: waits, running: items.length - waits };
}
