// The Stats page (hq#1920) over its host op (`cmux.stats.summary`, the mock host): the tiles show the
// summary in the person's units, the heatmap lines weekdays up in rows, a range click asks again,
// a reply for a range already left is dropped, the grid follows the summary it draws, a refresh
// mid-load starts no second scan, and a missing host says so instead of loading forever.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { formatDuration, heatmap, hourShares } from "../src/pages/stats/shape";
import type { PageClient } from "../src/pages/shared/pageClient";
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

test("with no host the page says where stats live", async () => {
  const { StatsStore } = await import("../src/pages/stats/store");
  const store = new StatsStore(null);
  await store.start();
  expect(store.getSnapshot()).toMatchObject({ unavailable: true, loading: false });
});
