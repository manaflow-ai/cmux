// l10n-allow-file: test fixtures.
// The GitHub page draws what is visible (the visible-only rule). The CI dashboard can hold thousands
// of jobs (GitHubChecks.swift reads up to 40 suites of 100 runs): at 1,000 and 10,000 jobs it mounts
// the same few rows, and a scroll step, a clock tick and an answer that changes one job draw again
// only the rows whose data changed. The files (at most 100, `files(first: 100)`) and the
// conversation (at most 50 comments and 30 reviews) are drawn whole, but expanding one file draws
// only that file again, and neither a file's toggle nor a re-read that changes one comment draws the
// other entries again. Before, every job was a mounted row, every tick drew them all, and every
// change to the page drew every file, check and entry again.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ConversationEntry, DashboardChecks, DashboardJob, PullRequestDetails } from "../src/pages/github/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "setInterval",
  "clearInterval",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
/** getBoundingClientRect calls since the last reset. */
let boxReads = 0;
/** The dashboard's one-second clock, captured so a test ticks it. */
let ticks: (() => void)[] = [];

/** Layout jsdom does not do: an item of the dashboard is as tall as its kind's estimate. */
const HEIGHTS: Record<string, number> = {
  title: 24,
  "title-gap": 32,
  fold: 24,
  "fold-gap": 32,
  line: 24,
  failure: 120,
};
const height = (element: Element) => {
  const kind = (element as HTMLElement).dataset?.size;
  if (kind) return HEIGHTS[kind] ?? 0;
  return element.classList.contains("gh-ci-row") ? 24 : 0;
};

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><div id=root></div></body></html>", {
    url: "https://cmux.test/github/",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return height(this);
    },
  });
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    boxReads += 1;
    const h = height(this);
    return { top: 0, left: 0, right: 800, bottom: h, width: 800, height: h, x: 0, y: 0, toJSON() {} } as DOMRect;
  };
  Object.assign(window, { ResizeObserver, scrollTo: () => {} });
  const win = window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.ResizeObserver = ResizeObserver;
  scope.getComputedStyle = window.getComputedStyle.bind(window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  // The dashboard's tick (useTicking) is the only interval on the page: captured, run by `tick`.
  scope.setInterval = (callback: () => void) => {
    ticks.push(callback);
    return ticks.length as unknown as ReturnType<typeof setInterval>;
  };
  scope.clearInterval = (handle: number) => {
    ticks[handle - 1] = () => {};
  };
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  ticks = [];
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { GitHubPage } = await import("../src/pages/github/GitHubPage");
const { GitHubStore } = await import("../src/pages/github/store");
const { createStrings } = await import("../src/pages/shared/i18n");
const { GitHubOps } = await import("../src/pages/github/types");
const { mockDetails, mockPullRequest, MOCK_URL } = await import("../src/pages/github/mockProvider");
const table = (await import("../src/pages/github/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

const NOW = Date.parse("2026-11-18T12:00:00Z");
/** The page's clock: a tick moves it a second. */
let clock = NOW;
const HEAD = "a1b2c3d4e5f6";

/** `count` jobs: three failed (one with a log), two running, the rest queued. */
function jobs(count: number): DashboardJob[] {
  return Array.from({ length: count }, (_, index): DashboardJob => {
    const state = index < 3 ? "failed" : index < 5 ? "running" : "queued";
    return {
      id: 1_000 + index,
      name: `job ${index}`,
      workflow: "CI",
      run: 77,
      state,
      startedAt: state === "queued" ? "" : "2026-11-18T11:50:00Z",
      completedAt: state === "failed" ? "2026-11-18T11:55:00Z" : "",
      url: `https://github.com/example/app/actions/runs/77/job/${1_000 + index}`,
      expected: 600,
      ...(index === 0 ? { failure: { step: "Run tests", excerpt: "expected 1, got 2" } } : {}),
    };
  });
}

const entry = (index: number, body = `Comment ${index}`): ConversationEntry => ({
  kind: index % 3 === 0 ? "review" : "comment",
  author: `user${index % 7}`,
  body,
  at: new Date(NOW - index * 60_000).toISOString(),
  url: `https://github.com/example/app/pull/482#c${index}`,
  state: index % 3 === 0 ? "commented" : null,
  comments: [],
});

/** The host as the page bridge is: each answer a new object (JSON), from fixtures a test changes. */
function host_(checks: DashboardChecks, details: PullRequestDetails) {
  const fixture = {
    checks,
    details,
    pullRequest: {
      ...mockPullRequest,
      changedFiles: 100,
      files: Array.from({ length: 100 }, (_, index) => ({
        path: `src/file${index}.ts`,
        additions: index,
        deletions: 1,
      })),
    },
  };
  const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
  const client = {
    async call(op: string) {
      if (op === GitHubOps.inspect) return clone({ pullRequest: fixture.pullRequest, fetchedAt: 1, reading: false });
      if (op === GitHubOps.details) return clone({ details: fixture.details });
      if (op === GitHubOps.checks) return clone({ checks: fixture.checks, reading: false });
      if (op === GitHubOps.diffFile) return { tooLarge: true };
      return {};
    },
    async subscribe() {
      return () => {};
    },
  };
  return { fixture, client };
}

const settle = async () => {
  for (let i = 0; i < 6; i++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
};

async function mount(count: number) {
  const details: PullRequestDetails = {
    ...mockDetails,
    headCommit: HEAD,
    conversation: Array.from({ length: 80 }, (_, index) => entry(index)),
    conversationTotal: 80,
    conversationRead: 80,
  };
  const { fixture, client } = host_({ head: HEAD, settled: false, jobs: jobs(count) }, details);
  const store = new GitHubStore(client as never, () => false);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  const strings = createStrings(table);
  act(() => root!.render(<GitHubPage store={store} strings={strings} now={() => clock} />));
  await act(async () => store.route(`#/pull?url=${encodeURIComponent(MOCK_URL)}`));
  await settle();
  return { store, fixture };
}

async function scrollWindow(y: number) {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: y });
  await act(async () => void dom.window.dispatchEvent(new dom.window.Event("scroll")));
  await settle();
}

const ciRows = () => host.querySelectorAll(".gh-ci-row .gh-ci-line");
const fileRows = () => host.querySelectorAll(".gh-file-row");
const entries = () => host.querySelectorAll(".gh-entry-head");

const results: Record<number, { rows: number; nodes: number }> = {};

for (const count of [1_000, 10_000]) {
  test(`at ${count} jobs the dashboard mounts a screen of rows and draws again only the rows that changed`, async () => {
    Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
    clock = NOW;
    const { store, fixture } = await mount(count);
    const rows = host.querySelectorAll(".gh-ci-row").length;
    expect(rows).toBeGreaterThan(10);
    expect(rows).toBeLessThanOrEqual(200);
    results[count] = { rows, nodes: host.querySelectorAll("*").length };
    console.log(`${count} jobs: ${rows} rows, ${results[count].nodes} nodes mounted`);
    // Screen readers keep each row's place in its group.
    const queued = host.querySelector(".gh-ci-row[data-check=queued]")!;
    expect(queued.getAttribute("aria-setsize")).toBe(String(count - 5));

    // A clock tick: only the running rows (their time counts up) draw again.
    const renders = mountedRowRenders(ciRows);
    renders.mark();
    clock += 1_000;
    act(() => ticks.forEach((tick) => tick()));
    expect(renders.since()).toBe(2);

    // One job changes (a queued job starts): only its row draws again.
    renders.mark();
    fixture.checks = {
      ...fixture.checks,
      jobs: fixture.checks.jobs.map((job, index) => (index === 6 ? { ...job, url: `${job.url}?again` } : job)),
    };
    await act(async () => store.loadChecks());
    await settle();
    expect(renders.since()).toBe(1);

    // One scroll step: the rows still mounted do not draw again, and no row's box is read.
    const names = () => new Set([...ciRows()].map((line) => line.textContent));
    const before = names();
    renders.mark();
    boxReads = 0;
    await scrollWindow(240);
    expect(host.querySelectorAll(".gh-ci-row").length).toBeLessThanOrEqual(200);
    const arrived = [...names()].filter((name) => !before.has(name)).length;
    expect(arrived).toBeGreaterThan(0);
    expect(renders.since()).toBe(arrived);
    expect(boxReads).toBeLessThan(40);
  });
}

test("1,000 and 10,000 jobs mount the same rows and DOM nodes, within 10 %", () => {
  const small = results[1_000]!;
  const large = results[10_000]!;
  expect(Math.abs(large.rows - small.rows)).toBeLessThanOrEqual(Math.ceil(small.rows * 0.1));
  expect(Math.abs(large.nodes - small.nodes)).toBeLessThanOrEqual(Math.ceil(small.nodes * 0.1));
});

test("expanding one file draws only that file again, and no conversation entry", async () => {
  const { store } = await mount(10);
  expect(fileRows().length).toBe(100);
  expect(entries().length).toBe(80);
  const files = mountedRowRenders(fileRows);
  const said = mountedRowRenders(entries);
  files.mark();
  said.mark();
  act(() => store.toggleFile("src/file7.ts"));
  await settle();
  expect(files.since()).toBe(1);
  expect(said.since()).toBe(0);
});

test("a re-read that changes one comment draws only that entry again", async () => {
  const { store, fixture } = await mount(10);
  const said = mountedRowRenders(entries);
  said.mark();
  // A new comment's edit: GitHub's updatedAt moves, the page reads the details again.
  fixture.details = {
    ...fixture.details,
    conversation: fixture.details.conversation.map((each, index) =>
      index === 4 ? entry(4, "Comment 4, edited") : each,
    ),
  };
  fixture.pullRequest = { ...fixture.pullRequest, updatedAt: "2026-11-18T11:59:00Z" };
  await act(async () => store.ask());
  await settle();
  expect(host.textContent).toContain("Comment 4, edited");
  expect(said.since()).toBe(1);
});

// Each row's link is a tab stop. jsdom moves no focus on Tab, so `tab()` does what a browser does:
// the next tab stop in document order takes focus (a browser then scrolls it in).
const TABBABLE = "button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex='-1'])";

async function tab(shift = false) {
  const document = dom.window.document;
  const stops = [...document.querySelectorAll<HTMLElement>(TABBABLE)];
  const next = stops[stops.indexOf(document.activeElement as HTMLElement) + (shift ? -1 : 1)];
  await act(async () => next?.focus());
  await settle();
}

const jobLink = (name: string) =>
  [...host.querySelectorAll<HTMLButtonElement>(".gh-ci-row .gh-row-link")].find((link) => link.textContent === name);
const focusedText = () => dom.window.document.activeElement?.textContent;

test("Tab from a focused row the page scrolled 20,000 px away from goes to the next job", async () => {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
  await mount(1_000);
  await act(async () => jobLink("job 30")!.focus());
  await settle();
  await scrollWindow(20_000);
  expect(jobLink("job 30")).toBeDefined();
  await tab();
  expect(focusedText()).toBe("job 31");
});

test("Shift-Tab from a focused row the page scrolled 20,000 px away from goes to the job before it", async () => {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
  await mount(1_000);
  await act(async () => jobLink("job 30")!.focus());
  await settle();
  await scrollWindow(20_000);
  await tab(true);
  expect(focusedText()).toBe("job 29");
});

test("Shift-Tab from the control after the dashboard enters it at the last job", async () => {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
  await mount(1_000);
  const stops = [...dom.window.document.querySelectorAll<HTMLElement>(TABBABLE)];
  const dashboard = host.querySelector(".gh-ci")!;
  const after = stops.find(
    (stop) =>
      !dashboard.contains(stop) &&
      dashboard.compareDocumentPosition(stop) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING,
  )!;
  await act(async () => after.focus());
  await tab(true);
  expect(focusedText()).toBe("job 999");
});
