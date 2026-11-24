// l10n-allow-file: generated fixture data (machine ids, member names, agent titles), not shipped UI.
// Generated team boards for the gallery, the dev loop, the tests and the perf harness. One seed
// gives one board, so a before and after measure the same data. The degenerate cases are on
// purpose: machines with no owner or a departed one, negative, missing, non-finite and string
// costs, names of 500 characters, a machine listed twice, audit rows for machines that are gone.
import type {
  BoardEvent,
  BoardSnapshot,
  MachineAuditRow,
  MachineSession,
  MachineState,
  TeamMachine,
  TeamMember,
} from "./types";

export interface FixtureOptions {
  machines: number;
  members?: number;
  seed?: number;
  /** Turn on the degenerate cases (default: on when there are more than 3 machines). */
  degenerate?: boolean;
  /** The clock the fixture's times count back from (ms). */
  now?: number;
}

/** A small, fast, seeded PRNG (mulberry32). */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const FIRST = [
  "Ada",
  "Grace",
  "Linus",
  "Margaret",
  "Ken",
  "Barbara",
  "Dennis",
  "Frances",
  "Alan",
  "Radia",
  "Edsger",
  "Hedy",
];
const LAST = ["Lovelace", "Hopper", "Torvalds", "Hamilton", "Thompson", "Liskov", "Ritchie", "Allen", "Kay", "Perlman"];
const AGENTS = ["claude", "codex"];
const TASKS = [
  "Fix the flaky upload test",
  "Port the settings page",
  "Review the billing PR",
  "Bisect the nightly crash",
  "Write the migration",
  "Profile the list scroll",
];
const STATES: MachineState[] = ["running", "running", "running", "running", "paused", "paused", "starting", "failed"];

export const FIXTURE_NOW = 1_794_312_000_000;
export const FIXTURE_SELF = "user_0000";

const hex = (random: () => number, length: number) => {
  let out = "";
  for (let i = 0; i < length; i += 1) out += Math.floor(random() * 16).toString(16);
  return out;
};

export function fixtureMembers(count: number, seed = 1): TeamMember[] {
  const random = rng(seed * 7919);
  return Array.from({ length: count }, (_, index) => {
    const name = `${FIRST[index % FIRST.length]} ${LAST[Math.floor(index / FIRST.length) % LAST.length]}`;
    return {
      user: index === 0 ? FIXTURE_SELF : `user_${hex(random, 20)}`,
      name:
        index > 0 && index % 37 === 0 ? undefined : `${name}${index >= FIRST.length * LAST.length ? ` ${index}` : ""}`,
      email: `${name.toLowerCase().replace(" ", ".")}${index}@example.com`,
    };
  });
}

export function fixtureBoard(options: FixtureOptions): BoardSnapshot {
  const { machines: count, seed = 1, now = FIXTURE_NOW } = options;
  const degenerate = options.degenerate ?? count > 3;
  const random = rng(seed);
  const members = fixtureMembers(options.members ?? Math.max(1, Math.min(200, Math.ceil(count / 25))), seed);
  const machines: TeamMachine[] = [];
  const sessions: Record<string, MachineSession[]> = {};
  const audit: MachineAuditRow[] = [];
  const byMachine: { machineId: string; hours: number; costUsd: number }[] = [];
  for (let index = 0; index < count; index += 1) {
    const id = `vm_${hex(random, 20)}`;
    const state =
      count <= 3 ? (["running", "running", "paused"] as const)[index]! : STATES[Math.floor(random() * STATES.length)]!;
    const hourlyUsd = [0.13224, 0.26448, 0.52896][Math.floor(random() * 3)]!;
    const createdAt = now - Math.floor(random() * 6 * 24 * 3_600_000);
    const hours = (now - createdAt) / 3_600_000;
    let totalUsd: unknown = Number((hours * hourlyUsd).toFixed(6));
    let creator: string | undefined = members[Math.floor(random() * members.length)]!.user;
    let name: string | null =
      random() < 0.3 ? `${TASKS[index % TASKS.length]!.toLowerCase().replace(/ /g, "-")}-${index}` : null;
    if (degenerate) {
      const roll = index % 50;
      if (roll === 1) creator = undefined; // no owner at all
      if (roll === 2) creator = `user_departed${index}`; // left the team
      if (roll === 3) creator = "";
      if (roll === 4) totalUsd = -3.5; // negative
      if (roll === 5) totalUsd = undefined; // missing
      if (roll === 6) totalUsd = "NaN"; // a wire string
      if (roll === 7) totalUsd = Number.POSITIVE_INFINITY;
      if (roll === 8) name = `${"a-very-long-machine-name-".repeat(20)}`.slice(0, 500);
      if (roll === 9) name = "雲の機械 · машина · آلة · 🤖 build box";
    }
    const machine: TeamMachine = {
      id,
      creator,
      state,
      createdAt,
      kind: "user",
      visibility: random() < 0.5 ? "team" : "private",
      provider: "freestyle-cloud",
      region: "global",
      shape: { vcpu: 2, memGiB: 4, diskGiB: 16 },
      present: random() < 0.15 ? [{ user: members[0]!.user, since: now - 60_000 }] : [],
      cost: {
        currency: "USD",
        estimated: true,
        hourlyUsd,
        idleHourlyUsd: hourlyUsd / 96,
        accruedUsd: 0,
        runningUsd: typeof totalUsd === "number" ? totalUsd : 0,
        totalUsd: totalUsd as number,
        runningSince: state === "running" ? createdAt : null,
      },
      workspace: null,
      name,
      error: state === "failed" ? { code: "machine.provider", message: "The provider stopped answering." } : undefined,
    };
    machines.push(machine);
    if (typeof totalUsd === "number" && Number.isFinite(totalUsd) && totalUsd >= 0)
      byMachine.push({ machineId: id, hours, costUsd: totalUsd });
    if (state === "running" && random() < 0.6) {
      const n = 1 + Math.floor(random() * 2);
      sessions[id] = Array.from({ length: n }, (_, k) => {
        const roll = random();
        const sessionState = roll < 0.2 ? "waiting" : roll < 0.8 ? "working" : "idle";
        return {
          id: `${id}-s${k}`,
          agent: AGENTS[(index + k) % AGENTS.length]!,
          title: TASKS[(index + k) % TASKS.length],
          state: sessionState,
          waitingSince: sessionState === "waiting" ? now - Math.floor(random() * 3_600_000) : undefined,
        } satisfies MachineSession;
      });
    }
  }
  if (degenerate && machines.length > 10) machines.push({ ...machines[10]! }); // listed twice
  for (let index = 0; index < Math.min(50, count * 2); index += 1) {
    const target = machines[Math.floor(random() * machines.length)]!;
    const agent = random() < 0.4;
    audit.push({
      at: now - index * 61_000,
      target: "machine",
      targetId: degenerate && index === 3 ? "vm_gone0000000000000000" : target.id,
      creator: target.creator ?? "",
      actor: agent ? "claude" : (target.creator ?? members[0]!.user),
      actorKind: agent ? "agent" : "person",
      action: ["resume", "pause", "snapshot", "create", "open"][index % 5]!,
      result: "ok",
    });
  }
  const knownCostUsd = byMachine.reduce((sum, row) => sum + row.costUsd, 0);
  return {
    machines,
    usage: {
      since: now - 30 * 24 * 3_600_000,
      until: now,
      knownCostUsd,
      totalCostUsd: knownCostUsd,
      byCreator: [],
      byStartedBy: [],
      byMachine,
      coverage: { scope: "team", recordedHistory: "all" },
    },
    audit,
    members,
    sessions,
    self: FIXTURE_SELF,
  };
}

/**
 * A stream of changes to `snapshot`'s machines, as the host would send them: cost ticks mostly,
 * some state flips, agents starting and stopping to wait, audit rows. Deterministic per seed.
 */
export function fixtureUpdates(snapshot: BoardSnapshot, count: number, seed = 2): BoardEvent[] {
  const random = rng(seed);
  const machines = snapshot.machines;
  const events: BoardEvent[] = [];
  if (machines.length === 0) return events;
  const at = FIXTURE_NOW;
  for (let index = 0; index < count; index += 1) {
    const machine = machines[Math.floor(random() * machines.length)]!;
    const roll = random();
    if (roll < 0.7) {
      const total =
        typeof machine.cost?.totalUsd === "number" && Number.isFinite(machine.cost.totalUsd)
          ? machine.cost.totalUsd
          : 0;
      events.push({
        kind: "machine",
        machine: { ...machine, cost: { ...machine.cost, totalUsd: total + 0.0001 * (index + 1) } },
      });
    } else if (roll < 0.8) {
      const state: MachineState = machine.state === "running" ? "paused" : "running";
      events.push({ kind: "machine", machine: { ...machine, state } });
    } else if (roll < 0.9) {
      events.push({
        kind: "sessions",
        machine: machine.id,
        sessions: [
          {
            id: `${machine.id}-u${index}`,
            agent: "claude",
            title: TASKS[index % TASKS.length],
            state: random() < 0.5 ? "waiting" : "working",
            waitingSince: at,
          },
        ],
      });
    } else {
      events.push({
        kind: "audit",
        row: {
          at: at + index,
          target: "machine",
          targetId: machine.id,
          creator: machine.creator ?? "",
          actor: "codex",
          actorKind: "agent",
          action: "resume",
          result: "ok",
        },
      });
    }
  }
  return events;
}
