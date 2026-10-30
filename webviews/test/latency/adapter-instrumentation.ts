// Serialized into the fixture. Installation owns one bounded run; finalization drains and
// disconnects the observer, including entries whose delivery callback has not run yet.
type State = { startAt: number; commits?: number; tasks: PerformanceEntry[]; observer?: PerformanceObserver };
type Scope = Window & { __latencyAdapterMetrics?: State; __latencyReactCommits?: number };
export interface AdapterInstrumentation {
  longTasks: number[] | null;
  reactCommits: number | null;
  instrumentationWindow: { startAt: number; endAt: number; source: string };
}

export function beginAdapterInstrumentation(): void {
  const scope = window as Scope;
  if (scope.__latencyAdapterMetrics) throw new Error("previous adapter instrumentation was not disposed");
  const state: State = { startAt: performance.now(), commits: scope.__latencyReactCommits, tasks: [] };
  scope.__latencyAdapterMetrics = state;
  try {
    if (window.PerformanceObserver?.supportedEntryTypes?.includes("longtask")) {
      state.observer = new window.PerformanceObserver((entries) => state.tasks.push(...entries.getEntries()));
      state.observer.observe({ type: "longtask", buffered: false });
    }
  } catch {
    state.observer?.disconnect();
    state.observer = undefined;
  }
}

export function endAdapterInstrumentation(): AdapterInstrumentation {
  const scope = window as Scope;
  const state = scope.__latencyAdapterMetrics;
  if (!state) throw new Error("adapter instrumentation window is missing");
  try {
    const endAt = performance.now();
    state.tasks.push(...(state.observer?.takeRecords() ?? []));
    const after = scope.__latencyReactCommits;
    const commits = state.commits;
    return {
      longTasks: state.observer
        ? state.tasks
            .filter((entry) => entry.startTime <= endAt && entry.startTime + entry.duration >= state.startAt)
            .map((entry) => entry.duration)
        : null,
      reactCommits:
        typeof commits === "number" &&
        Number.isInteger(commits) &&
        commits >= 0 &&
        typeof after === "number" &&
        Number.isInteger(after) &&
        after >= commits
          ? after - commits
          : null,
      instrumentationWindow: {
        startAt: state.startAt,
        endAt,
        source: "PerformanceObserver longtask and React.Profiler counter around measureRun",
      },
    };
  } finally {
    state.observer?.disconnect();
    delete scope.__latencyAdapterMetrics;
  }
}
