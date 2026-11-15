// An in-memory `cmux.stats.summary` provider for the browser dev loop (`/stats/?mock`) and the
// gallery: a deterministic few weeks of agent work, shaped like acpmux's `_acpmux/stats` answer.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { StatsOps, type DayStats, type StatsSummary, type UsagePatterns } from "./types";

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

/** `busy` is a working machine; `empty` has no sessions in range yet. */
export type MockStatsKind = "busy" | "empty";

/** The usage patterns a mock answer carries: `on` with counts, `off` (the default setting), or none (an older acpmux). */
export type MockUsageKind = "on" | "off" | "none";

export function mockUsagePatterns(kind: MockUsageKind, until: number): UsagePatterns | undefined {
  if (kind === "none") return undefined;
  if (kind === "off")
    return { enabled: false, rollup: { since: 0, updated: 0, counts: {}, days: {}, hours: [], peaks: {} } };
  return {
    enabled: true,
    rollup: {
      since: until - 21 * DAY_MS,
      updated: until,
      counts: {
        "agent-chat": { claude: 212, codex: 96, opencode: 9 },
        "agent-prompt": { claude: 1840, codex: 702, opencode: 41 },
        tokens: { input: 18_200_000, output: 2_410_000, "cache-read": 402_000_000 },
        layout: { "split-right": 318, "split-down": 77 },
        command: { "new-browser-tab": 640, "new-tab": 512, split: 395, "select-tab": 4120, "send-keys": 220 },
        operation: { "tab.focus": 3880, "pane.split": 0, "workspace.create": 61, "tab.create_browser": 410 },
        connection: { unix: 940, ws: 210, remote: 14 },
        "acpmux-connection": { app: 300, local: 1200, peer: 22 },
        machine: { a1b2c3d4e5f6: 40, "0f1e2d3c4b5a": 12, "9a8b7c6d5e4f": 3 },
        client: { "cmux-next": 280, cli: 900 },
      },
      days: {},
      hours: [],
      peaks: { "connections.open": 17 },
    },
  };
}

export class MockStatsProvider implements PageClient {
  constructor(
    private readonly kind: MockStatsKind = "busy",
    private readonly failure?: { code: string; message: string },
    private readonly usage: MockUsageKind = "on",
  ) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.failure) throw pageError(this.failure.code, this.failure.message);
    if (op !== StatsOps.summary) throw pageError("cmux.op.unknown", op);
    const { days = 84, tzOffsetMinutes = 0 } = (params ?? {}) as { days?: number; tzOffsetMinutes?: number };
    const until = Date.now();
    const summary = mockSummary(this.kind, days, tzOffsetMinutes, until);
    const usagePatterns = mockUsagePatterns(this.usage, until);
    return (usagePatterns ? { ...summary, usagePatterns } : summary) as R;
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

export function mockSummary(
  kind: MockStatsKind,
  rangeDays: number,
  tzOffsetMinutes: number,
  until: number,
): StatsSummary {
  const today = Math.floor((until + tzOffsetMinutes * 60_000) / DAY_MS);
  const days: DayStats[] = [];
  if (kind === "busy") {
    for (let day = today - rangeDays + 1; day <= today; day++) {
      // Weekends are light, one week in five is off: a deterministic stand-in for real use.
      const weekday = (((day + 4) % 7) + 7) % 7;
      const seed = (day * 2_654_435_761) % 997;
      if (weekday === 0 || seed % 5 === 0) continue;
      const hours = weekday === 6 ? 1 + (seed % 2) : 2 + (seed % 7);
      days.push({
        day: new Date(day * DAY_MS).toISOString().slice(0, 10),
        turns: hours * 6 + (seed % 9),
        workingMs: hours * HOUR_MS + (seed % 50) * 60_000,
      });
    }
  }
  const workingMs = days.reduce((sum, day) => sum + day.workingMs, 0);
  const turns = days.reduce((sum, day) => sum + day.turns, 0);
  const curve = [0, 0, 0, 0, 0, 0, 0, 1, 3, 6, 8, 7, 4, 6, 8, 9, 8, 6, 4, 3, 3, 2, 1, 0];
  const weight = curve.reduce((sum, value) => sum + value, 0);
  const share = (part: number) => Math.round(workingMs * part);
  return {
    since: until - rangeDays * DAY_MS,
    until,
    tzOffsetMinutes,
    sessions: Math.round(turns / 9),
    turns,
    turnsCompleted: Math.round(turns * 0.86),
    turnsCancelled: Math.round(turns * 0.1),
    turnsFailed: turns - Math.round(turns * 0.86) - Math.round(turns * 0.1),
    prompts: turns,
    steers: Math.round(turns * 0.12),
    toolCalls: turns * 14,
    permissionRequests: Math.round(turns * 0.3),
    permissionAuto: Math.round(turns * 0.9),
    permissionAnswered: Math.round(turns * 0.3) - Math.round(turns * 0.01),
    permissionUnanswered: Math.round(turns * 0.01),
    // Summed per question, so two open at once count twice: at least the time spent waiting.
    permissionWaitMs: Math.round(workingMs * 0.044),
    permissionWaitMaxMs: days.length ? 14 * 60_000 + 20_000 : 0,
    limitErrors: days.length ? 3 : 0,
    workingMs,
    waitingMs: Math.round(workingMs * 0.04),
    peakParallel: days.length ? 5 : 0,
    peakParallelAt: days.length ? until - 2 * DAY_MS : null,
    harnesses: days.length
      ? [
          {
            harness: "claude",
            sessions: Math.round(turns / 15),
            turns: Math.round(turns * 0.6),
            workingMs: share(0.6),
          },
          { harness: "codex", sessions: Math.round(turns / 30), turns: Math.round(turns * 0.3), workingMs: share(0.3) },
          {
            harness: "opencode",
            sessions: Math.round(turns / 90),
            turns: Math.round(turns * 0.1),
            workingMs: share(0.1),
          },
        ]
      : [],
    days,
    hours: curve.map((value) => share(value / weight)),
    streak: days.length ? { current: 4, longest: 11 } : { current: 0, longest: 0 },
  };
}
