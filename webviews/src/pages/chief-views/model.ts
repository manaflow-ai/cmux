// What the views show, derived from the app's replies (types.ts). Pure: no clock, no DOM; every
// function takes `now` or the start of today. The ordering is the old Lanes view's (#20363; that
// view and its agent-activity/lanes.ts are gone from the base): what needs a person first, the
// longest idle next, working last.
import type { AgentState, ChiefAgent, FleetMachine, FleetPR, LandingPR, LandingReply } from "./types";

export const LOCAL_MACHINE = "local";
/** The label that marks a pull request as handed to the autolander. */
export const READY_LABEL = "ready-to-land";

const RANK: Record<AgentState, number> = { failed: 0, waiting: 1, idle: 2, working: 3 };

/** The Lanes view's order: failed, waiting, idle (longest first), working (newest first). */
export function agentOrder(a: ChiefAgent, b: ChiefAgent): number {
  if (RANK[a.state] !== RANK[b.state]) return RANK[a.state] - RANK[b.state];
  const since = (a.since ?? 0) - (b.since ?? 0);
  if (since !== 0) return a.state === "working" ? -since : since;
  return a.title.localeCompare(b.title);
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

/** A person should look: it waits on them or failed. */
export const needsYou = (agent: ChiefAgent) => agent.state === "waiting" || agent.state === "failed";

/** The pull request an agent works on: `#123`, `pull/123` or `pr-123` in its title, task or branch. */
export function agentPR(agent: ChiefAgent, known?: ReadonlyMap<string, number>): number | undefined {
  if (agent.branch && known?.has(agent.branch)) return known.get(agent.branch);
  for (const text of [agent.title, agent.task, agent.branch, agent.name]) {
    if (!text) continue;
    const match = /(?:#|pull\/|\bpr[-_ ]?)(\d{3,7})\b/i.exec(text);
    if (match) return Number(match[1]);
  }
  return undefined;
}

/** Branch → pull request, from the dashboard's runs. */
export function branchPRs(prs: readonly FleetPR[] | undefined): Map<string, number> {
  const map = new Map<string, number>();
  for (const pr of prs ?? []) if (pr.branch) map.set(pr.branch, pr.number);
  return map;
}

/** The last two path components of a folder, for a row: worktrees are often `<task>/<repo>`, and
 * the repo's name alone says nothing ("work-needsyou/cmux" for ~/Projects/work-needsyou/cmux). */
export function folderName(folder: string | null | undefined): string | undefined {
  if (!folder) return undefined;
  const parts = folder.replace(/\/+$/, "").split("/").filter(Boolean);
  return parts.slice(-2).join("/") || folder;
}

export type MachineGroup = { id: string; name?: string; agents: ChiefAgent[]; attention: number };

const matches = (agent: ChiefAgent, needle: string) =>
  [
    agent.title,
    agent.name,
    agent.task ?? "",
    agent.folder ?? "",
    agent.machineName ?? agent.machine,
    agent.error ?? "",
  ].some((value) => value.toLocaleLowerCase().includes(needle));

/** Every agent by machine (this Mac first, then by name), each machine in the Lanes order. */
export function byMachine(agents: readonly ChiefAgent[], filter = ""): MachineGroup[] {
  const needle = filter.trim().toLocaleLowerCase();
  const groups = new Map<string, MachineGroup>();
  for (const agent of agents) {
    if (needle && !matches(agent, needle)) continue;
    const group = groups.get(agent.machine) ?? {
      id: agent.machine,
      name: agent.machineName ?? undefined,
      agents: [],
      attention: 0,
    };
    group.agents.push(agent);
    if (needsYou(agent)) group.attention += 1;
    groups.set(agent.machine, group);
  }
  for (const group of groups.values()) group.agents.sort(agentOrder);
  return [...groups.values()].sort((a, b) => {
    if ((a.id === LOCAL_MACHINE) !== (b.id === LOCAL_MACHINE)) return a.id === LOCAL_MACHINE ? -1 : 1;
    return (a.name ?? a.id).localeCompare(b.name ?? b.id);
  });
}

export type StateCounts = Record<AgentState, number>;

export function stateCounts(agents: readonly ChiefAgent[]): StateCounts {
  const counts: StateCounts = { working: 0, waiting: 0, idle: 0, failed: 0 };
  for (const agent of agents) counts[agent.state] += 1;
  return counts;
}

const sameDay = (iso: string | null | undefined, startOfDay: number) => !!iso && Date.parse(iso) >= startOfDay;

/** A pull request card on the board or in Landing, with the agents that work on it. */
export type PRCard = LandingPR & { owners: ChiefAgent[]; ci?: string };

/** Agents by the pull request they work on. */
export function ownersByPR(agents: readonly ChiefAgent[], prs?: readonly FleetPR[]): Map<number, ChiefAgent[]> {
  const known = branchPRs(prs);
  const owners = new Map<number, ChiefAgent[]>();
  for (const agent of agents) {
    const pr = agentPR(agent, known);
    if (pr === undefined) continue;
    owners.set(pr, [...(owners.get(pr) ?? []), agent]);
  }
  return owners;
}

export type CIKind = "red" | "green" | "running" | "queued";

/** The dashboard's CI word for a run (`failed`, `running`, ...), as one of four kinds. */
export function ciKind(status: string | undefined): CIKind | undefined {
  if (!status) return undefined;
  if (/fail|red|error/i.test(status)) return "red";
  if (/pass|success|green|done/i.test(status)) return "green";
  if (/run|progress/i.test(status)) return "running";
  if (/queue|wait|pending/i.test(status)) return "queued";
  return undefined;
}

export type LandingLanes = { open: PRCard[]; ready: PRCard[]; red: PRCard[]; merged: PRCard[] };

/**
 * The Landing view's four lanes: open, labeled `ready-to-land`, CI red (from the dashboard's runs)
 * and merged today. A red labeled PR shows under red: the label does not land it while it is red.
 */
export function landingLanes(
  landing: LandingReply | undefined,
  agents: readonly ChiefAgent[],
  fleetPRs: readonly FleetPR[] | undefined,
  startOfDay: number,
): LandingLanes {
  const owners = ownersByPR(agents, fleetPRs);
  const ci = new Map((fleetPRs ?? []).map((pr) => [pr.number, pr.status]));
  const card = (pr: LandingPR): PRCard => ({
    ...pr,
    owners: owners.get(pr.number) ?? [],
    ci: ci.get(pr.number),
  });
  const lanes: LandingLanes = { open: [], ready: [], red: [], merged: [] };
  for (const pr of landing?.open ?? []) {
    const next = card(pr);
    if (ciKind(next.ci) === "red") lanes.red.push(next);
    else if (pr.labels.includes(READY_LABEL)) lanes.ready.push(next);
    else lanes.open.push(next);
  }
  for (const pr of landing?.merged ?? []) if (sameDay(pr.mergedAt, startOfDay)) lanes.merged.push(card(pr));
  lanes.merged.sort((a, b) => Date.parse(b.mergedAt ?? "") - Date.parse(a.mergedAt ?? ""));
  return lanes;
}

export type BoardColumns = {
  working: ChiefAgent[];
  needsYou: ChiefAgent[];
  ready: PRCard[];
  landed: PRCard[];
};

/** The Agent board: agents that work and agents that need you, then the PRs ready to land and landed today. */
export function boardColumns(agents: readonly ChiefAgent[], lanes: LandingLanes): BoardColumns {
  const sorted = [...agents].sort(agentOrder);
  return {
    working: sorted.filter((agent) => agent.state === "working"),
    needsYou: sorted.filter(needsYou),
    ready: lanes.ready,
    landed: lanes.merged,
  };
}

export type TimelineKind = "spawned" | "waiting" | "failed" | "finished" | "opened" | "merged";

export type TimelineEvent = {
  id: string;
  at: number;
  kind: TimelineKind;
  /** The agent's title or the PR's title. */
  title: string;
  agent?: ChiefAgent;
  pr?: LandingPR;
  detail?: string | null;
};

/**
 * Today's events across agents, newest first, derived from what the records say happened when:
 * an agent started (`createdAt`), entered waiting, failed or idle (`since`), a pull request was
 * opened (`createdAt`) or merged (`mergedAt`). Nothing is kept between reads, so a reload shows the
 * same feed.
 */
export function timeline(
  agents: readonly ChiefAgent[],
  landing: LandingReply | undefined,
  startOfDay: number,
): TimelineEvent[] {
  const events: TimelineEvent[] = [];
  for (const agent of agents) {
    if (agent.createdAt && agent.createdAt >= startOfDay)
      events.push({
        id: `spawned:${agent.id}`,
        at: agent.createdAt,
        kind: "spawned",
        title: agent.title,
        agent,
      });
    if (agent.since && agent.since >= startOfDay && agent.state !== "working") {
      const kind: TimelineKind = agent.state === "idle" ? "finished" : agent.state;
      events.push({
        id: `${kind}:${agent.id}`,
        at: agent.since,
        kind,
        title: agent.title,
        agent,
        detail: agent.state === "failed" ? agent.error : agent.task,
      });
    }
  }
  for (const pr of landing?.open ?? [])
    if (sameDay(pr.createdAt, startOfDay))
      events.push({
        id: `opened:${pr.number}`,
        at: Date.parse(pr.createdAt!),
        kind: "opened",
        title: pr.title,
        pr,
      });
  for (const pr of landing?.merged ?? [])
    if (sameDay(pr.mergedAt, startOfDay))
      events.push({
        id: `merged:${pr.number}`,
        at: Date.parse(pr.mergedAt!),
        kind: "merged",
        title: pr.title,
        pr,
      });
  return events.sort((a, b) => b.at - a.at || a.id.localeCompare(b.id));
}

/** Agents on a fleet machine: the agent's machine name or id is the host or its first label. */
export function agentsOnHost(agents: readonly ChiefAgent[], host: string): number {
  const short = host.toLocaleLowerCase().split(".")[0];
  return agents.filter((agent) => {
    const name = (agent.machineName ?? agent.machine).toLocaleLowerCase();
    return name === short || name.split(".")[0] === short;
  }).length;
}

/** Load per core, 0 to 1 and over when oversubscribed; undefined without both numbers. */
export function loadPerCore(machine: FleetMachine): number | undefined {
  if (machine.load == null || !machine.ncpu) return undefined;
  return machine.load / machine.ncpu;
}

/** Fleet totals for the header tiles. */
export function fleetTotals(machines: readonly FleetMachine[]) {
  let busy = 0;
  let online = 0;
  let unreachable = 0;
  for (const machine of machines) {
    busy += machine.runnersBusy;
    online += machine.runnersOnline;
    if (machine.error) unreachable += 1;
  }
  return { busy, online, unreachable, machines: machines.length };
}

/** Local midnight of `now`. */
export function startOfDay(now: number): number {
  const day = new Date(now);
  return new Date(day.getFullYear(), day.getMonth(), day.getDate()).getTime();
}
