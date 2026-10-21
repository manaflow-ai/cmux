// l10n-allow-file: dev and gallery fixtures (agent titles, task lines, hosts, PR titles), not shipped UI.
// An in-memory `cmux.chief_views.*` provider for the browser dev loop (`/chief-views/?mock`) and the
// gallery: a dozen agents on four machines, a CI dashboard of six minis and the repository's
// open and merged-today pull requests. Times are relative to `now`, so every run reads the same.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import {
  ChiefViewsErrors,
  ChiefViewsOps,
  type ChiefAgent,
  type ChiefAgentsReply,
  type FleetReply,
  type LandingReply,
} from "./types";

const MIN = 60_000;
const HOUR = 60 * MIN;

/** The instant the fixtures end: 2026-10-20 16:40 local. */
export const FIXTURE_NOW = new Date(2026, 9, 20, 16, 40).getTime();

/** `busy`: a working day; `empty`: nothing running; `fleet-unset`: no dashboard named yet. */
export type MockChiefViewsKind = "busy" | "empty" | "fleet-unset" | "fleet-down" | "landing-down";

export function mockAgents(now: number = FIXTURE_NOW): ChiefAgent[] {
  const ago = (ms: number) => now - ms;
  return [
    {
      id: "s-chief-views",
      kind: "chat",
      name: "chiefviews",
      title: "Chief view gallery for Home",
      machine: "local",
      folder: "/Users/leo/Projects/work-chiefviews/cmux",
      state: "working",
      task: "Writing the Fleet view's machine table",
      lastOutputAt: ago(20_000),
      since: ago(42 * MIN),
      createdAt: ago(3 * HOUR),
      harness: "claude",
    },
    {
      id: "s-needsyou",
      kind: "chat",
      name: "needsyou",
      title: "Needs-you view: group by decision",
      machine: "local",
      folder: "/Users/leo/Projects/work-needsyou/cmux",
      state: "waiting",
      task: "Asks: keep the old inbox behind a toggle? (#22630)",
      lastOutputAt: ago(14 * MIN),
      since: ago(14 * MIN),
      createdAt: ago(5 * HOUR),
      harness: "claude",
    },
    {
      id: "t-newtab",
      kind: "terminal",
      name: "New Tab layouts",
      title: "New Tab layouts",
      machine: "local",
      folder: "/Users/leo/Projects/work-newtab/cmux",
      state: "idle",
      task: "Pushed the dots switcher; waiting for CI on #22618",
      lastOutputAt: ago(2 * HOUR + 10 * MIN),
      since: ago(2 * HOUR + 10 * MIN),
      createdAt: ago(7 * HOUR),
      harness: "claude",
      branch: "newtab-dots",
    },
    {
      id: "s-inspector",
      kind: "chat",
      name: "huge-blue/inspector",
      title: "Inspector panel: pin sections",
      machine: "huge-blue",
      machineName: "huge-blue",
      folder: "/home/leo/work-inspector/cmux",
      state: "working",
      task: "Running the webview tests for the pinned section list",
      lastOutputAt: ago(45_000),
      since: ago(18 * MIN),
      createdAt: ago(4 * HOUR),
      harness: "codex",
    },
    {
      id: "s-pickers",
      kind: "chat",
      name: "huge-blue/pickers",
      title: "Model pickers: effort track",
      machine: "huge-blue",
      machineName: "huge-blue",
      folder: "/home/leo/work-pickers/cmux",
      state: "failed",
      error: "Credit balance too low",
      lastOutputAt: ago(51 * MIN),
      since: ago(51 * MIN),
      createdAt: ago(6 * HOUR),
      harness: "claude",
    },
    {
      id: "s-import",
      kind: "chat",
      name: "huge-blue/import",
      title: "Import cards from Arc and Chrome",
      machine: "huge-blue",
      machineName: "huge-blue",
      folder: "/home/leo/work-import/cmux",
      state: "working",
      task: "Addressing the review bot's thread on #22604",
      lastOutputAt: ago(3 * MIN),
      since: ago(9 * MIN),
      createdAt: ago(8 * HOUR),
      harness: "claude",
    },
    {
      id: "s-glaeda",
      kind: "chat",
      name: "big-red/glaeda",
      title: "glaeda: admission by live load",
      machine: "big-red",
      machineName: "big-red",
      folder: "/home/leo/Glaeda-fleet-eviction-fix",
      state: "idle",
      task: "Cut v0.48.2 and promoted it to stable",
      lastOutputAt: ago(5 * HOUR),
      since: ago(5 * HOUR),
      createdAt: ago(26 * HOUR),
      harness: "codex",
    },
    {
      id: "s-ci-wall",
      kind: "chat",
      name: "big-red/ci-wall",
      title: "CI: terminal suites on 16 vCPU",
      machine: "big-red",
      machineName: "big-red",
      folder: "/home/leo/cmux-ci-runner-cost",
      state: "waiting",
      task: "Permission: run fleet sudo on aws-m4pro-9?",
      lastOutputAt: ago(6 * MIN),
      since: ago(6 * MIN),
      createdAt: ago(2 * HOUR),
      harness: "claude",
    },
    {
      id: "t-cmux16",
      kind: "terminal",
      name: "nightly guard",
      title: "Nightly rollback guard",
      machine: "cmux16",
      machineName: "cmux16",
      folder: "/Users/agent/nightly-guard",
      state: "working",
      task: "Watching run 39505838491 for #22613",
      lastOutputAt: ago(70_000),
      since: ago(31 * MIN),
      createdAt: ago(90 * MIN),
      harness: "claude",
      branch: "nightly-rollback-guard",
    },
  ];
}

export function mockFleet(now: number = FIXTURE_NOW): FleetReply {
  const machine = (
    host: string,
    load: number,
    ncpu: number,
    cpuPct: number,
    memFreePct: number,
    busy: number,
    online: number,
    error?: string,
  ) => ({
    host,
    load,
    ncpu,
    cpuPct,
    memFreePct,
    runnersBusy: busy,
    runnersOnline: online,
    error: error ?? null,
  });
  return {
    updated: new Date(now - 40_000).toISOString(),
    queued: 23,
    machines: [
      machine("cmux7s-mac-mini", 36.2, 14, 92, 62, 3, 4),
      machine("cmux10s-mac-mini", 14.1, 14, 100, 41, 4, 4),
      machine("cmux12s-mac-mini", 6.3, 14, 71, 58, 2, 4),
      machine("cmux16", 2.1, 14, 3, 80, 0, 3),
      machine("cmux18", 22.9, 24, 97, 22, 5, 6),
      machine("aws-m4pro-9", 0, 14, 0, 0, 0, 0, "console locked"),
    ],
    prs: [
      { number: 22618, title: "New Tab: dots switcher", branch: "newtab-dots", status: "running" },
      {
        number: 22604,
        title: "Import cards from Arc and Chrome",
        branch: "import-cards",
        status: "failed",
      },
      {
        number: 22613,
        title: "ci(next): terminal suites on Blacksmith 16 vCPU",
        branch: "nightly-rollback-guard",
        status: "passed",
      },
    ],
  };
}

export function mockLanding(now: number = FIXTURE_NOW): LandingReply {
  const iso = (ms: number) => new Date(now - ms).toISOString();
  const pr = (number: number, title: string, author: string, labels: string[], created: number, merged?: number) => ({
    number,
    title,
    url: `https://github.com/manaflow-ai/cmux/pull/${number}`,
    author,
    labels,
    createdAt: iso(created),
    mergedAt: merged === undefined ? null : iso(merged),
  });
  return {
    repo: "manaflow-ai/cmux",
    base: "feat-cmux-next",
    open: [
      pr(22630, "Needs-you view: group by decision", "teamleaderleo", [], 3 * HOUR),
      pr(22618, "New Tab: dots switcher", "teamleaderleo", ["ready-to-land", "risk:normal"], 6 * HOUR),
      pr(22604, "Import cards from Arc and Chrome", "teamleaderleo", ["ready-to-land"], 26 * HOUR),
      pr(22597, "Inspector: pin sections", "lawrencecchen", ["risk:normal"], 2 * HOUR),
    ],
    merged: [
      pr(
        22613,
        "ci(next): terminal suites run their Linux-able half on Blacksmith 16 vCPU",
        "teamleaderleo",
        [],
        9 * HOUR,
        95 * MIN,
      ),
      pr(
        22591,
        "Home: the emoji button opens the picker for the message box",
        "lawrencecchen",
        [],
        11 * HOUR,
        3 * HOUR,
      ),
      pr(22055, "agent pane: hover cards on session references", "teamleaderleo", [], 30 * HOUR, 4 * HOUR),
    ],
  };
}

export class MockChiefViewsProvider implements PageClient {
  private fleetURL: string | undefined;

  constructor(
    private readonly kind: MockChiefViewsKind = "busy",
    private readonly now: number = FIXTURE_NOW,
  ) {
    this.fleetURL = kind === "fleet-unset" ? undefined : "https://ci.example.test/";
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    switch (op) {
      case ChiefViewsOps.agents:
        return {
          agents: this.kind === "empty" ? [] : mockAgents(this.now),
        } satisfies ChiefAgentsReply as R;
      case ChiefViewsOps.fleet:
        if (!this.fleetURL)
          throw pageError(ChiefViewsErrors.fleetUnavailable, "No CI dashboard is set.", false, {
            configured: false,
          });
        if (this.kind === "fleet-down")
          throw pageError(ChiefViewsErrors.fleetUnavailable, "The dashboard did not answer.", true, {
            configured: true,
          });
        return mockFleet(this.now) as R;
      case ChiefViewsOps.setFleetURL:
        this.fleetURL = String((params as { url?: unknown })?.url ?? "") || undefined;
        return {} as R;
      case ChiefViewsOps.landing:
        if (this.kind === "landing-down") throw pageError(ChiefViewsErrors.landingUnavailable, "Rate limited.", true);
        return (
          this.kind === "empty"
            ? { repo: "manaflow-ai/cmux", base: "feat-cmux-next", open: [], merged: [] }
            : mockLanding(this.now)
        ) as R;
      case ChiefViewsOps.open:
      case ChiefViewsOps.openURL:
        return {} as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}
