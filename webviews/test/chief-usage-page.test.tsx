// The Chief Usage page (plans/cmux-next/chief-usage-analytics-DESIGN.md) over its host op
// (`cmux.chief_usage.summary`, the mock host): the formatters read in the person's units, the
// fixture shows the Oct 19 cache fix and the subagent costs, the page renders the summary (tiles,
// one bar per bucket, a table row per group, a link per linked top unit), the window picker and
// the grouping ask again with the right params, a failed read shows the page's own words, and every
// string exists in every locale.
import { afterAll, beforeAll, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LOCALES } from "../scripts/pages/gen-strings.mjs";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { FIXTURE_NOW, mockUsageSummary } from "../src/pages/chief-usage/mockProvider";
import {
  formatMs,
  formatPercent,
  formatTokens,
  formatUSD,
  stackedBars,
  tokenTotal,
  type Plot,
} from "../src/pages/chief-usage/shape";
import type { UsageQuery, UsageSummary } from "../src/pages/chief-usage/types";

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

const query = (since: UsageQuery["since"], by: UsageQuery["by"] = "chief"): UsageQuery => ({ since, by, top: 10 });

test("dollars, tokens, percents and durations read in the person's units", () => {
  expect(formatUSD(41.2, "en")).toBe("$41.20");
  expect(formatUSD(1234.4, "en")).toBe("$1,234");
  expect(formatUSD(0.0042, "en")).toBe("$0.0042");
  expect(formatTokens(1_234_567, "en")).toBe("1.2M");
  expect(formatTokens(912, "en")).toBe("912");
  expect(formatPercent(0.934, "en")).toBe("93.4%");
  expect(formatPercent(null, "en")).toBe("–");
  expect(formatMs(850, "en")).toBe("850ms");
  expect(formatMs(6_100, "en")).toBe("6.1s");
  expect(formatMs(40_000, "en")).toBe("40s");
  expect(formatMs(65_000, "en")).toBe("1m 5s");
  expect(formatMs(null, "en")).toBe("–");
});

test("stacked bars stay inside the plot, one per bucket, empty kinds left out", () => {
  const plot: Plot = { width: 400, height: 200, left: 40, right: 40, top: 10, bottom: 20 };
  const point = (input: number, cache_read: number) => ({
    t: 0,
    units: 1,
    turns: 1,
    input,
    output: 10,
    cache_read,
    cache_write: 0,
    usd: 0,
    hit: null,
    ms_p50: null,
    ms_p95: null,
  });
  const bars = stackedBars([point(100, 890), point(0, 0)], plot, 1_000);
  expect(bars.length).toBe(2);
  expect(bars[0]!.segments.map((segment) => segment.kind)).toEqual(["input", "cache_read", "output"]);
  const top = Math.min(...bars[0]!.segments.map((segment) => segment.y));
  // The bar is exactly the max: its top meets the plot's top (to float precision).
  expect(top).toBeCloseTo(plot.top, 5);
  expect(bars[0]!.segments[0]!.y + bars[0]!.segments[0]!.height).toBeCloseTo(plot.height - plot.bottom, 5);
  expect(bars[1]!.segments.length).toBe(1);
  expect(bars[1]!.x).toBeGreaterThan(bars[0]!.x);
});

test("the fixture shows the Oct 19 cache fix and the subagents' cost", () => {
  const week = mockUsageSummary("busy", query("7d"), FIXTURE_NOW);
  expect(week.bucket).toBe("day");
  const fix = new Date(2026, 9, 19).getTime();
  const before = week.series.filter((point) => point.t < fix && point.hit !== null);
  const after = week.series.filter((point) => point.t > fix && point.hit !== null);
  expect(before.length).toBeGreaterThan(0);
  expect(before.every((point) => point.hit! < 0.55)).toBe(true);
  expect(after.every((point) => point.hit! > 0.9)).toBe(true);
  const agents = mockUsageSummary("busy", query("30d", "agent"), FIXTURE_NOW).by;
  const cost = (key: string) => agents.find((group) => group.key === key)?.usd ?? 0;
  expect(cost("a102")).toBeGreaterThan(2);
  expect(cost("a102")).toBeLessThan(6);
  expect(cost("a241")).toBeGreaterThan(50);
  expect(cost("a241")).toBeLessThan(110);
  expect(mockUsageSummary("busy", query("24h"), FIXTURE_NOW).bucket).toBe("hour");
  expect(mockUsageSummary("busy", query("1y"), FIXTURE_NOW).bucket).toBe("week");
  expect(mockUsageSummary("empty", query("7d"), FIXTURE_NOW).totals.units).toBe(0);
});

test("the page renders the summary and asks again for the window and grouping picked", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChiefUsagePage } = await import("../src/pages/chief-usage/ChiefUsagePage");
  const { ChiefUsageStore } = await import("../src/pages/chief-usage/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/chief-usage/generated/strings.json")).default;
  const asked: { op: string; params: UsageQuery }[] = [];
  const pending: ((summary: UsageSummary) => void)[] = [];
  const client: PageClient = {
    call: <R,>(op: string, params: unknown) =>
      new Promise<R>((resolve) => {
        asked.push({ op, params: params as UsageQuery });
        pending.push((summary) => resolve(summary as R));
      }),
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new ChiefUsageStore(client);
  const strings = createStrings(table, ["en"]);
  root = createRoot(host);
  act(() => root!.render(<ChiefUsagePage store={store} strings={strings} />));
  await act(async () => void store.start());
  expect(asked).toEqual([{ op: "cmux.chief_usage.summary", params: { since: "7d", by: "chief", top: 10 } }]);
  expect(host.textContent).toContain("Loading…");

  const summary = mockUsageSummary("busy", query("7d"), FIXTURE_NOW);
  await act(async () => pending.shift()!(summary));
  const tile = (name: string) => host.querySelector(`[data-tile="${name}"] .cu-tile-value`)?.textContent;
  expect(tile("cost")).toBe(formatUSD(summary.totals.usd, "en"));
  expect(tile("tokens")).toBe(formatTokens(tokenTotal(summary.totals), "en"));
  expect(tile("hit")).toBe(formatPercent(summary.totals.hit, "en"));
  expect(tile("turns")).toBe(String(summary.totals.turns));
  expect(tile("turnTime")).toBe(`${formatMs(summary.totals.ms_p50, "en")} / ${formatMs(summary.totals.ms_p95, "en")}`);
  expect(summary.series.length).toBeGreaterThanOrEqual(7);
  expect(host.querySelectorAll(".cu-bar").length).toBe(summary.series.length);
  expect(host.querySelector(".cu-line.cu-cost")?.getAttribute("d")).toMatch(/^M/);
  expect(host.querySelectorAll(".cu-table tbody tr").length).toBe(summary.by.length);
  expect(summary.by.length).toBe(2);
  expect(host.querySelectorAll(".cu-top li").length).toBe(summary.top.length);
  const links = [...host.querySelectorAll<HTMLAnchorElement>("a.cu-top-row")].map((node) => node.getAttribute("href"));
  const linked = summary.top.flatMap((unit) => (unit.link ? [unit.link] : []));
  expect(linked.length).toBeGreaterThan(0);
  expect(links).toEqual(linked);

  // Hovering a bar's slot shows that bucket's tooltip.
  const hit = host.querySelector<SVGRectElement>(".cu-chart .cu-hit[data-index='0']")!;
  await act(async () => {
    hit.dispatchEvent(new host.ownerDocument.defaultView!.MouseEvent("mouseover", { bubbles: true }));
  });
  expect(host.querySelector(".cu-tooltip")?.textContent).toContain("Cache read");

  // A window click asks for that window; the grouping keeps.
  const button = (since: string) => host.querySelector<HTMLButtonElement>(`.cu-window[data-window="${since}"]`)!;
  await act(async () => button("30d").click());
  expect(asked.at(-1)?.params).toEqual({ since: "30d", by: "chief", top: 10 });
  expect(button("30d").getAttribute("aria-pressed")).toBe("true");
  // Refresh mid-load starts no second read.
  await act(() => store.refresh());
  expect(asked.length).toBe(2);
  await act(async () => pending.shift()!(mockUsageSummary("busy", query("30d"), FIXTURE_NOW)));

  // The grouping asks again for the same window.
  const select = host.querySelector<HTMLSelectElement>(".cu-by select")!;
  await act(async () => {
    select.value = "agent";
    select.dispatchEvent(new host.ownerDocument.defaultView!.Event("change", { bubbles: true }));
  });
  expect(asked.at(-1)?.params).toEqual({ since: "30d", by: "agent", top: 10 });
  const byAgent = mockUsageSummary("busy", query("30d", "agent"), FIXTURE_NOW);
  await act(async () => pending.shift()!(byAgent));
  const names = [...host.querySelectorAll(".cu-table tbody .cu-row-name")].map((node) => node.textContent);
  expect(names).toContain("Chief itself");
  expect(names).toContain("a241");

  // An empty window says so and still draws its buckets.
  await act(async () => button("7d").click());
  await act(async () => pending.shift()!(mockUsageSummary("empty", query("7d", "agent"), FIXTURE_NOW)));
  expect(host.textContent).toContain(strings.t("chiefUsage.page.empty"));
  expect(host.querySelectorAll(".cu-top li").length).toBe(0);
});

test("a failed read shows the page's own words, never the tool's error text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChiefUsagePage } = await import("../src/pages/chief-usage/ChiefUsagePage");
  const { ChiefUsageStore } = await import("../src/pages/chief-usage/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/chief-usage/generated/strings.json")).default;
  const failures = [
    pageError("cmux.chief_usage.failed", "usage: No such file or directory (os error 2)", true),
    pageError("cmux.chief_usage.unavailable", "The Chief usage tool is not in this build.", true),
  ];
  const client: PageClient = {
    call: () => Promise.reject(failures.shift()),
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new ChiefUsageStore(client);
  const strings = createStrings(table, ["en"]);
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ChiefUsagePage store={store} strings={strings} />));
  await act(() => store.start());
  expect(host.textContent).not.toContain("os error");
  expect(host.textContent).toContain(strings.t("chiefUsage.page.failed"));
  await act(() => store.refresh());
  expect(host.textContent).toContain("The Chief usage tool is not in this build.");
});

test("with no host the page says where usage lives", async () => {
  const { ChiefUsageStore } = await import("../src/pages/chief-usage/store");
  const store = new ChiefUsageStore(null);
  await store.start();
  expect(store.getSnapshot()).toMatchObject({ unavailable: true, loading: false });
});

test("every string the page uses exists in every locale, with its placeholders", () => {
  const dir = path.join(import.meta.dir, "../src/pages/chief-usage");
  const catalog = JSON.parse(fs.readFileSync(path.join(dir, "Localizable.xcstrings"), "utf8")) as {
    strings: Record<string, { localizations: Record<string, { stringUnit: { value: string } }> }>;
  };
  // Keys the sources name, plus the ones they build from a list.
  const sources = [
    ...fs.readdirSync(dir).filter((file) => /\.tsx?$/.test(file)),
    ...fs.readdirSync(path.join(dir, "designs")).map((file) => `designs/${file}`),
  ].map((file) => fs.readFileSync(path.join(dir, file), "utf8"));
  const used = new Set(
    sources.flatMap((source) => [...source.matchAll(/"(chiefUsage\.[A-Za-z0-9.]+)"/g)].map((m) => m[1]!)),
  );
  for (const window of ["24h", "7d", "30d", "90d", "1y"]) used.add(`chiefUsage.window.${window}`);
  for (const by of ["chief", "agent", "model", "harness", "kind"]) used.add(`chiefUsage.by.${by}`);
  for (const kind of ["turn", "compactor", "subagent"]) used.add(`chiefUsage.kind.${kind}`);
  for (const tab of ["cost", "tokens", "cache", "latency"]) used.add(`chiefUsage.tabs.${tab}`);
  expect(LOCALES.length).toBe(21);
  const missing: string[] = [];
  for (const key of used) {
    const entry = catalog.strings[key];
    if (!entry) {
      missing.push(key);
      continue;
    }
    const english = entry.localizations.en?.stringUnit.value ?? "";
    const placeholders = (english.match(/%(\d+\$)?@/g) ?? []).length;
    for (const locale of LOCALES) {
      const value = entry.localizations[locale]?.stringUnit.value;
      if (!value) missing.push(`${key} ${locale}`);
      else if ((value.match(/%(\d+\$)?@/g) ?? []).length !== placeholders)
        missing.push(`${key} ${locale} placeholders`);
    }
  }
  expect(missing).toEqual([]);
});
