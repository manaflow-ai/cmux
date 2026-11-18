// l10n-allow-file: bench fixture names, not shipped UI.
// The real GitHub page over a pull request whose head has N jobs (`#n=10000`), for
// bench/github-page-visible-only.bench.ts: a stand-in host that answers as the page bridge does (a
// new object per answer) and lets the bench change one job. Three jobs fail (one with its log), two
// run, the rest wait. `benchRowRenders` counts the dashboard rows that rendered since its last mark,
// read from each mounted row's fiber (test/support/mountedRowRenders.ts), so the page carries no
// counter. The dashboard's one-second clock is captured so `benchTick` runs one tick on demand.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/github/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/github/generated/strings.json";
import { GitHubPage } from "../../src/pages/github/GitHubPage";
import { mockDetails, mockPullRequest, MOCK_URL } from "../../src/pages/github/mockProvider";
import { GitHubStore } from "../../src/pages/github/store";
import { GitHubOps, type DashboardChecks, type DashboardJob } from "../../src/pages/github/types";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th job's link and has the page read the checks again. */
    benchChangeOne(index: number): Promise<void>;
    /** Runs the dashboard's one-second clock once. */
    benchTick(): void;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const HEAD = "a1b2c3d4e5f6";
const started = Date.now() - 10 * 60_000;

const jobs: DashboardJob[] = Array.from({ length: n }, (_, index) => {
  const state = index < 3 ? "failed" : index < 5 ? "running" : "queued";
  return {
    id: 1_000 + index,
    name: `integration shard ${index}`,
    workflow: "CI",
    run: 77,
    state,
    startedAt: state === "queued" ? "" : new Date(started).toISOString(),
    completedAt: state === "failed" ? new Date(started + 5 * 60_000).toISOString() : "",
    url: `https://github.com/example/app/actions/runs/77/job/${1_000 + index}`,
    expected: 600,
    ...(index === 0
      ? { failure: { step: "Run tests", excerpt: "FAIL test/sidebar.test.ts\n  expected 1, got 2\n  at reorder" } }
      : {}),
  } satisfies DashboardJob;
});
let checks: DashboardChecks = { head: HEAD, settled: false, jobs };
const details = { ...mockDetails, headCommit: HEAD };

const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const client = {
  async call(op: string) {
    if (op === GitHubOps.inspect) return clone({ pullRequest: mockPullRequest, fetchedAt: 1, reading: false });
    if (op === GitHubOps.details) return clone({ details });
    if (op === GitHubOps.checks) return clone({ checks, reading: false });
    return {};
  },
  async subscribe() {
    return () => {};
  },
};

// The page's only interval is the dashboard's clock: held, so the bench ticks it when it measures.
const ticks: (() => void)[] = [];
const realSetInterval = window.setInterval.bind(window);
window.setInterval = ((callback: () => void, ms?: number) => {
  if (ms === 1000) {
    ticks.push(callback);
    return ticks.length;
  }
  return realSetInterval(callback, ms);
}) as typeof window.setInterval;
const realClearInterval = window.clearInterval.bind(window);
window.clearInterval = ((handle: number) => {
  if (handle > 0 && handle <= ticks.length) ticks[handle - 1] = () => {};
  else realClearInterval(handle);
}) as typeof window.clearInterval;

const store = new GitHubStore(client as never, () => false);
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(<GitHubPage store={store} strings={strings} />);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".gh-ci-row .gh-ci-line"));
window.benchTick = () => ticks.forEach((tick) => tick());
window.benchChangeOne = async (index) => {
  checks = {
    ...checks,
    jobs: checks.jobs.map((job, at) => (at === index ? { ...job, url: `${job.url}?${Date.now()}` } : job)),
  };
  await store.loadChecks();
};
void store.route(`#/pull?url=${encodeURIComponent(MOCK_URL)}`).then(async () => {
  await store.loadChecks();
  window.benchReady = true;
});
