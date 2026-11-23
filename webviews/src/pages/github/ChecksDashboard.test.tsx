// The CI dashboard on the page (Leo, 2026-11-07: "here's your big dashboard") keeps what the
// rollup it replaced said: a failing check that also fails on the base branch is marked, and a
// read cut short says more checks exist and still shows the rollup's failures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { GitHubPage } from "./GitHubPage";
import { mockChecks, mockDetails, mockPullRequest, MOCK_URL } from "./mockProvider";
import type { GitHubSnapshot, GitHubStore } from "./store";
import { routedPullRequest, type DashboardChecks } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

function render(checks: DashboardChecks): string {
  const snapshot: GitHubSnapshot = {
    target: routedPullRequest(`#/pull?url=${encodeURIComponent(MOCK_URL)}`),
    pullRequest: mockPullRequest,
    details: mockDetails,
    detailsFor: mockPullRequest.updatedAt,
    reading: false,
    answered: true,
    patches: {},
    merge: { phase: "idle" },
    rerun: { phase: "idle" },
    checks,
  };
  const store = { subscribe: () => () => {}, getSnapshot: () => snapshot } as unknown as GitHubStore;
  return renderToStaticMarkup(
    <GitHubPage store={store} strings={strings} now={() => Date.parse("2026-11-05T03:00:00Z")} />,
  );
}

test("a failing job that also fails on the base branch says so on the dashboard", () => {
  // The rollup marks "lint" as failing on the base; the dashboard's "lint" job is failing too.
  const checks = {
    ...mockChecks,
    jobs: mockChecks.jobs.map((job) => (job.name === "lint" ? { ...job, state: "failed" as const } : job)),
  };
  expect(render(checks)).toContain(en["github.checks.onBase"]!);
  expect(render(mockChecks)).not.toContain(en["github.checks.onBase"]!);
});

test("a cut-short read says more exist and keeps the rollup's failure", () => {
  const passed = {
    ...mockChecks,
    settled: true,
    jobs: mockChecks.jobs.filter((job) => job.name !== "unit tests" && job.state === "passed"),
  };
  expect(render(passed)).not.toContain(en["github.checks.more"]!);
  expect(render(passed)).not.toContain("unit tests");
  const html = render({ ...passed, settled: false, truncated: true });
  expect(html).toContain(en["github.checks.more"]!);
  // "unit tests" fails only in the rollup: past the read's window, it is still a failing row.
  expect(html).toContain("unit tests");
});
