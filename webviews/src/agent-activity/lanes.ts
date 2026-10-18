// The lanes view (cx-v9k2f): every acpmux session on this Mac and the acpmux peers it mirrors,
// with the lane acpmux decided for it. Grouped by machine, then by the coordinator that started
// it (`mux.parent`); what needs a person comes first, so an agent dead on "Credit balance too
// low" or idle for hours is the first thing on the page.

export type LaneState = "working" | "input" | "idle" | "failed" | "lost";
export type Lane = {
  id: string;
  name: string;
  title: string;
  peer?: string | null;
  parent?: string | null;
  state: LaneState;
  since?: number | null;
  error?: string | null;
  /** Existing sessionId → workspace binding, used when jumping to the row. */
  workspaceId?: string | null;
};
export type LaneGroup = { id: string; title?: string; lanes: Lane[]; attention: number };
export type LaneMachine = { id: string; name: string; groups: LaneGroup[]; attention: number };
export type LaneStrings = {
  thisMac: string;
  laneWorking: string;
  laneInput: string;
  laneIdle: string;
  laneFailed: string;
  laneLost: string;
  lanesOwn: string;
  /** `{state} · {duration}`, so a locale can order them. */
  laneStatus: string;
};

/** A person should look: it waits on them, failed or was lost. */
export const needsAttention = (lane: Lane) =>
  lane.state === "input" || lane.state === "failed" || lane.state === "lost";

/** How many lanes need a person. */
export const attentionCount = (lanes: Lane[]) => lanes.filter(needsAttention).length;

const rank: Record<LaneState, number> = { failed: 0, lost: 1, input: 2, idle: 3, working: 4 };

/** Failed, lost, waiting, idle (the longest idle first), then working (the newest first). */
export function laneOrder(a: Lane, b: Lane): number {
  if (rank[a.state] !== rank[b.state]) return rank[a.state] - rank[b.state];
  const since = (a.since ?? 0) - (b.since ?? 0);
  if (since !== 0) return a.state === "working" ? -since : since;
  return a.title.localeCompare(b.title);
}

function matches(lane: Lane, filter: string): boolean {
  const needle = filter.trim().toLocaleLowerCase();
  if (!needle) return true;
  return [lane.title, lane.name, lane.peer ?? "", lane.parent ?? "", lane.error ?? ""].some((value) =>
    value.toLocaleLowerCase().includes(needle),
  );
}

/**
 * The lanes by machine (this Mac first), then by coordinator. A coordinator's own session heads
 * the group of the lanes it started; lanes no coordinator started share one group.
 */
export function laneMachines(lanes: Lane[], filter: string, strings: LaneStrings): LaneMachine[] {
  const byMachine = new Map<string, Lane[]>();
  for (const lane of lanes) {
    const machine = lane.peer ?? "local";
    byMachine.set(machine, [...(byMachine.get(machine) ?? []), lane]);
  }
  return [...byMachine.entries()]
    .sort(([a], [b]) => ((a === "local") !== (b === "local") ? (a === "local" ? -1 : 1) : a.localeCompare(b)))
    .map(([id, all]) => {
      const parents = new Set(all.map((lane) => lane.parent).filter((p): p is string => !!p));
      const headOf = (lane: Lane) =>
        [lane.name, lane.id, lane.name.split("/").at(-1) ?? ""].find((key) => parents.has(key));
      const groups = new Map<string, Lane[]>();
      for (const lane of all.filter((lane) => matches(lane, filter))) {
        const key = lane.parent ?? headOf(lane) ?? "";
        groups.set(key, [...(groups.get(key) ?? []), lane]);
      }
      const sorted = [...groups.entries()]
        .map(([key, members]): LaneGroup => {
          const head = all.find((lane) => headOf(lane) === key);
          const rest = members.filter((lane) => lane !== head).sort(laneOrder);
          return {
            id: key,
            title: key ? (head?.title ?? key) : strings.lanesOwn,
            lanes: head && members.includes(head) ? [head, ...rest] : rest,
            attention: attentionCount(members),
          };
        })
        .sort((a, b) => {
          if ((a.id === "") !== (b.id === "")) return a.id === "" ? 1 : -1;
          if (a.attention !== b.attention) return b.attention - a.attention;
          return (a.title ?? "").localeCompare(b.title ?? "");
        });
      return {
        id,
        name: id === "local" ? strings.thisMac : id,
        groups: sorted,
        attention: sorted.reduce((sum, group) => sum + group.attention, 0),
      };
    })
    .filter((machine) => machine.groups.length > 0);
}

/** A short duration in the page's locale: "4 min", "3 hr", "2 days" (narrow units). */
export function shortDuration(ms: number, locale?: string): string {
  const minutes = Math.max(0, Math.round(ms / 60_000));
  const [value, unit] =
    minutes < 60
      ? [Math.max(1, minutes), "minute"]
      : minutes < 48 * 60
        ? [Math.round(minutes / 60), "hour"]
        : [Math.round(minutes / (24 * 60)), "day"];
  return new Intl.NumberFormat(locale, { style: "unit", unit, unitDisplay: "narrow" }).format(value);
}

/** The lane's state in words, and for how long: "Idle · 3h" (`strings.laneStatus`). */
export function laneStatus(lane: Lane, now: number, strings: LaneStrings, locale?: string): string {
  const word = {
    working: strings.laneWorking,
    input: strings.laneInput,
    idle: strings.laneIdle,
    failed: strings.laneFailed,
    lost: strings.laneLost,
  }[lane.state];
  if (!lane.since) return word;
  return strings.laneStatus.replace("{state}", word).replace("{duration}", shortDuration(now - lane.since, locale));
}
