import { setTrayTucked } from "../chatDisplay";
import { subagentStatus } from "../summary/subagentStatusListModel";
import type { TrayItem } from "./runningTray";
import { asksPerson } from "./trayAttention";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

/// The tab's count as it reads: the real count, never a cap (Leo, 2026-11-22: "this can probably
/// afford to show more than 99 numbers"). Up to 999 it is the number itself ("128"); past that a
/// compact one with one decimal under ten ("1.2k", "12k", "128k", "1.2M"), rounded down so it never
/// claims more than runs. So it is at most four characters, and the pill's width (pullTabCountWidth)
/// steps only when the number gains or loses a digit or a unit.
export function pullTabCountText(running: number): string {
  const n = Math.max(0, Math.floor(running));
  if (n < 1_000) return String(n);
  const [scale, unit] = n < 1_000_000 ? [1_000, "k"] : [1_000_000, "M"];
  // Whole tenths of the unit, in integers (2,300 / 100 is 23, never 22.999...).
  const tenths = Math.floor(n / (scale / 10));
  if (tenths >= 10_000) return `999${unit}`;
  if (tenths < 100) return `${Math.floor(tenths / 10)}${tenths % 10 === 0 ? "" : `.${tenths % 10}`}${unit}`;
  return `${Math.floor(tenths / 10)}${unit}`;
}

/// The count's width in the count's own `ch` (one tabular digit): each digit and unit a full `ch`,
/// the decimal point half of one. TrayPullTab.tsx sizes the slot with it and the composer's top line
/// leaves a gap as wide (subagents.css `data-mark`).
export function pullTabCountWidth(text: string): number {
  let width = 0;
  for (const char of text) width += char === "." ? 0.5 : 1;
  return width;
}

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
