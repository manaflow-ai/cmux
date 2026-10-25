// The Stats page (hq#1920) over its host op (`cmux.stats.summary`, the mock host): the tiles show the
// summary in the person's units, the heatmap lines weekdays up in rows, a range click asks again,
// a reply for a range already left is dropped, the grid follows the summary it draws, a refresh
// mid-load starts no second scan, and a missing host says so instead of loading forever.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import {
  attentionRows,
  formatDay,
  formatDuration,
  formatHour,
  formatWait,
  heatmap,
  hourShares,
} from "../src/pages/stats/shape";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { mockSummary } from "../src/pages/stats/mockProvider";
import type { StatsSummary } from "../src/pages/stats/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** 2026-10-12T12:00Z, a Monday. */
const NOON = Date.UTC(2026, 9, 12, 12);

test("durations read as hours and minutes without plural strings", () => {
  expect(formatDuration(0, "en")).toBe("0m");
  expect(formatDuration(45 * 60_000, "en")).toBe("45m");
  expect(formatDuration(3 * 3_600_000, "en")).toBe("3h");
  expect(formatDuration(200 * 60_000, "en")).toBe("3h 20m");
});

test("waits keep their seconds under ten minutes", () => {
  expect(formatWait(0, "en")).toBe("0s");
  expect(formatWait(12_400, "en")).toBe("12s");
  expect(formatWait(59_600, "en")).toBe("1m");
  expect(formatWait(89_000, "en")).toBe("1m 29s");
  expect(formatWait(599_000, "en")).toBe("9m 59s");
  expect(formatWait(14 * 60_000 + 20_000, "en")).toBe("14m");
  expect(formatWait(200 * 60_000, "en")).toBe("3h 20m");
});

test("attention rows show what acpmux sent and hide what an older daemon did not", () => {
  const base = mockSummary("busy", 7, 0, NOON);
  const summary: StatsSummary = {
    ...base,
    turns: 40,
    steers: 6,
    permissionAnswered: 4,
    permissionUnanswered: 1,
    permissionWaitMs: 100_000,
    permissionWaitMaxMs: 61_000,
    limitErrors: 2,
  };
  expect(attentionRows(summary)).toEqual([
    { key: "stats.attention.averageWait", wait: 25_000 },
    { key: "stats.attention.longestWait", wait: 61_000 },
    { key: "stats.attention.answered", count: 4 },
    { key: "stats.attention.unanswered", count: 1 },
    { key: "stats.attention.limitErrors", count: 2 },
    { key: "stats.attention.steersPerTurn", ratio: 0.15 },
  ]);
  // No question answered yet: no wait to average, but the counts still read.
  expect(
    attentionRows({ ...summary, permissionAnswered: 0, permissionWaitMs: 0, permissionWaitMaxMs: 0 }).map(
      (row) => row.key,
    ),
  ).toEqual([
    "stats.attention.answered",
    "stats.attention.unanswered",
    "stats.attention.limitErrors",
    "stats.attention.steersPerTurn",
  ]);
  // An older daemon sends none of the new fields; no turns means no steers per turn.
  const {
    permissionAnswered: _a,
    permissionUnanswered: _u,
    permissionWaitMs: _w,
    permissionWaitMaxMs: _m,
    limitErrors: _l,
    ...older
  } = summary;
  expect(attentionRows(older).map((row) => row.key)).toEqual(["stats.attention.steersPerTurn"]);
  expect(attentionRows({ ...older, turns: 0, steers: 0 })).toEqual([]);
});

test("the heatmap pads to Sunday and scales levels to the busiest day", () => {
  const cells = heatmap(
    [
      { day: "2026-10-11", turns: 2, workingMs: 1 },
      { day: "2026-10-12", turns: 9, workingMs: 4 },
    ],
    NOON,
    0,
    7,
  );
  // The range starts Tuesday 10-06: two padding cells (Sunday, Monday) first.
  expect(cells.slice(0, 2).every((cell) => cell.day === undefined)).toBe(true);
  expect(cells[2]?.day).toBe("2026-10-06");
  expect(cells.at(-1)).toEqual({ day: "2026-10-12", turns: 9, workingMs: 4, level: 4 });
  expect(cells.at(-2)?.level).toBe(1);
  expect(cells.length).toBe(9);
  // At UTC-14 the same instant is still 10-11 there.
  expect(heatmap([], NOON, -14 * 60, 7).at(-1)?.day).toBe("2026-10-11");
  expect(hourShares([0, 2, 4]).slice(0, 4)).toEqual([0, 0.5, 1, 0]);
});

test("a busy partial day before the drawn range does not dim the drawn days", () => {
  // acpmux's since is an instant, not a local midnight, so the summary can carry one older day.
  const cells = heatmap(
    [
      { day: "2026-10-05", turns: 50, workingMs: 100 },
      { day: "2026-10-12", turns: 9, workingMs: 4 },
    ],
    NOON,
    0,
    7,
  );
  expect(cells.some((cell) => cell.day === "2026-10-05")).toBe(false);
  expect(cells.at(-1)?.level).toBe(4);
});

test("tooltip days and hours read in the person's language", () => {
  expect(formatDay("2026-10-12", "en")).toBe("Mon, Oct 12");
  // ICU data versions differ on the comma after a German short weekday ("Mo., 12. Okt." here
  // before, "Mo. 12. Okt." from bun 1.4.2 on the fleet): the words and their order are what matter.
  expect(formatDay("2026-10-12", "de")).toMatch(/^Mo\.,? 12\. Okt\.$/);
  expect(formatHour(0, "en")).toBe("12 AM");
  expect(formatHour(13, "en")).toBe("1 PM");
  expect(formatHour(13, "de")).toBe("13 Uhr");
});

test("the page shows the summary, switches range and drops a stale reply", async () => {
  const { createRoot } = await import("react-dom/client");
  const { StatsPage } = await import("../src/pages/stats/StatsPage");
  const { StatsStore } = await import("../src/pages/stats/store");
  const { mockSummary } = await import("../src/pages/stats/mockProvider");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/stats/generated/strings.json")).default;

  const asked: { days: number; tzOffsetMinutes: number }[] = [];
  const pending: ((summary: StatsSummary) => void)[] = [];
  const client: PageClient = {
    call: <R,>(_op: string, params: unknown) => {
      const ask = params as { days: number; tzOffsetMinutes: number };
      asked.push(ask);
      return new Promise<R>((resolve) => pending.push((summary) => resolve(summary as R)));
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new StatsStore(client, () => 120);
  root = createRoot(host);
  act(() => root!.render(<StatsPage store={store} strings={createStrings(table, ["en"])} />));
  await act(async () => void store.start());
  expect(asked).toEqual([{ days: 84, tzOffsetMinutes: 120 }]);
  expect(host.textContent).toContain("Loading…");

  const summary = mockSummary("busy", 84, 120, NOON);
  await act(async () => pending.shift()!(summary));
  const tile = (label: string) =>
    [...host.querySelectorAll(".stats-tile")]
      .find((node) => node.querySelector(".stats-tile-label")?.textContent === label)
      ?.querySelector(".stats-tile-value")?.textContent;
  expect(tile("Agent time")).toBe(formatDuration(summary.workingMs, "en"));
  expect(tile("Most at once")).toBe("5");
  expect(tile("Streak")).toBe("4 days");
  expect(host.querySelectorAll(".stats-heat:not(.is-padding)").length).toBe(84);
  const attention = Object.fromEntries(
    [...host.querySelectorAll(".stats-attention .stats-outcome")].map((node) => [
      node.querySelector("dt")?.textContent,
      node.querySelector("dd")?.textContent,
    ]),
  );
  expect(attention).toEqual({
    "Average wait": formatWait(summary.permissionWaitMs! / summary.permissionAnswered!, "en"),
    "Longest wait": formatWait(summary.permissionWaitMaxMs!, "en"),
    "Questions answered": String(summary.permissionAnswered),
    "Questions unanswered": String(summary.permissionUnanswered),
    "Limit errors": String(summary.limitErrors),
    "Steers per turn": new Intl.NumberFormat("en", { maximumFractionDigits: 2 }).format(summary.steers / summary.turns),
  });
  expect([...host.querySelectorAll(".stats-harness-name")].map((node) => node.textContent)).toEqual([
    "Claude Code",
    "Codex",
    "OpenCode",
  ]);

  // Week, then Month before the week answers: the week's late reply must not land.
  const button = (label: string) =>
    [...host.querySelectorAll<HTMLButtonElement>(".stats-range")].find((node) => node.textContent === label)!;
  await act(async () => button("Week").click());
  await act(async () => button("Month").click());
  expect(asked.map((ask) => ask.days)).toEqual([84, 7, 30]);
  // While Month loads, the 12-week summary keeps its own 84-day grid.
  expect(host.querySelectorAll(".stats-heat:not(.is-padding)").length).toBe(84);
  // Coming back to the tab mid-load does not start another scan of every log.
  await act(() => store.refresh());
  expect(asked.length).toBe(3);
  await act(async () => pending.shift()!(mockSummary("busy", 7, 120, NOON)));
  expect(store.getSnapshot().range).toBe(30);
  expect(store.getSnapshot().summary).toBe(summary);
  await act(async () => pending.shift()!(mockSummary("empty", 30, 120, NOON)));
  expect(button("Month").getAttribute("aria-pressed")).toBe("true");
  expect(host.textContent).toContain("No agent turns in this range yet.");
  expect(host.querySelectorAll(".stats-heat:not(.is-padding)").length).toBe(30);
});

test("a failed read shows the page's own words, never acpmux's error text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { StatsPage } = await import("../src/pages/stats/StatsPage");
  const { StatsStore } = await import("../src/pages/stats/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/stats/generated/strings.json")).default;
  const failures = [
    pageError("cmux.stats.failed", "No such file or directory (os error 2)", true),
    pageError("cmux.stats.unavailable", "The agent service is not running.", true),
  ];
  const client: PageClient = {
    call: () => Promise.reject(failures.shift()),
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new StatsStore(client, () => 0);
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<StatsPage store={store} strings={createStrings(table, ["en"])} />));
  await act(() => store.start());
  expect(host.textContent).not.toContain("os error");
  expect(host.textContent).toContain(createStrings(table, ["en"]).t("stats.page.failed"));
  // The app's own unavailable message is already in the person's language.
  await act(() => store.refresh());
  expect(host.textContent).toContain("The agent service is not running.");
});

test("picking the range that is already loading starts no second scan", async () => {
  const { StatsStore } = await import("../src/pages/stats/store");
  let calls = 0;
  const client: PageClient = {
    call: () => {
      calls++;
      return new Promise(() => {});
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new StatsStore(client, () => 0);
  void store.start();
  void store.setRange(store.getSnapshot().range);
  expect(calls).toBe(1);
  void store.setRange(7);
  expect(calls).toBe(2);
});

test("with no host the page says where stats live", async () => {
  const { StatsStore } = await import("../src/pages/stats/store");
  const store = new StatsStore(null);
  await store.start();
  expect(store.getSnapshot()).toMatchObject({ unavailable: true, loading: false });
});

async function renderRange(days: 7 | 30 | 84) {
  const { createRoot } = await import("react-dom/client");
  const { StatsPage } = await import("../src/pages/stats/StatsPage");
  const { StatsStore } = await import("../src/pages/stats/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/stats/generated/strings.json")).default;
  const client: PageClient = {
    call: <R,>(_op: string, params: unknown) =>
      Promise.resolve(mockSummary("busy", (params as { days: number }).days, 120, NOON) as R),
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new StatsStore(client, () => 120);
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<StatsPage store={store} strings={createStrings(table, ["en"])} />));
  await act(() => store.setRange(days));
  return [...host.querySelectorAll(".stats-days .stats-day")].map(
    (node) => node.querySelector(".stats-day-label")?.textContent ?? "",
  );
}

test("a week draws its seven days in one row under their weekday names, today last", async () => {
  expect(await renderRange(7)).toEqual(["Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Mon"]);
  expect(host.querySelector(".stats-heatmap")).toBeNull();
  expect(host.querySelectorAll(".stats-heat:not(.is-padding)").length).toBe(7);
});

test("a month draws one row of days, dated today and every seventh day before it", async () => {
  const labels = await renderRange(30);
  expect(labels.length).toBe(30);
  expect(labels.filter(Boolean)).toEqual(["14", "21", "28", "5", "12"]);
  expect(labels.at(-1)).toBe("12");
});

test("twelve weeks keep the week-column heatmap", async () => {
  expect(await renderRange(84)).toEqual([]);
  expect(host.querySelectorAll(".stats-heatmap .stats-heat:not(.is-padding)").length).toBe(84);
});

test("picking the default range before the first read still reads it", async () => {
  const { StatsStore } = await import("../src/pages/stats/store");
  let calls = 0;
  const client: PageClient = {
    call: () => {
      calls++;
      return new Promise(() => {});
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new StatsStore(client, () => 0);
  void store.setRange(store.getSnapshot().range);
  expect(calls).toBe(1);
});
