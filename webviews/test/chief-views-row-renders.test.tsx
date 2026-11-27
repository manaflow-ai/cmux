// The Chief views' rows render only when their own data changed: a minute passing draws no row (each
// "4 min" stamp keeps its own clock and wakes when its words change), and the app's agents stream,
// which sends every agent on each change, draws only the changed agent's row. Counted from React's
// commits (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { ChiefAgent, FleetReply, LandingReply } from "../src/pages/chief-views/types";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const NOW = Date.UTC(2026, 10, 18, 12, 0, 0);

// A fresh object per agent each event, as the app's JSON is. Agent `i` last wrote `i` minutes ago
// (wrapping at 3 hours), so a minute changes the words of the stamps under an hour old.
const agents = (n: number, task = (_: number) => "Working"): ChiefAgent[] =>
  Array.from({ length: n }, (_, index) => ({
    id: `a${index}`,
    kind: "chat",
    name: `lane-${index}`,
    title: `Agent ${index} on #${40_000 + index}`,
    machine: "local",
    state: "working",
    task: task(index),
    lastOutputAt: NOW - (index % 180) * 60_000 - 10_000,
    createdAt: NOW - 3_600_000,
  }));

function client(first: ChiefAgent[], landing?: LandingReply, fleet?: FleetReply) {
  let emit: (reply: { agents: ChiefAgent[] }) => void = () => {};
  const page: PageClient = {
    async call<R>(op: string): Promise<R> {
      if (op === "cmux.chief_views.agents") return { agents: first } as R;
      if (op === "cmux.chief_views.landing" && landing) return structuredClone(landing) as R;
      // A fresh copy per read, as the app's JSON is.
      if (op === "cmux.chief_views.fleet" && fleet) return structuredClone(fleet) as R;
      throw new Error(`no ${op}`);
    },
    async subscribe<E>(_stream: string, onEvent: (data: E, seq: number) => void) {
      emit = (reply) => onEvent(reply as E, 0);
      return () => {};
    },
    handle: () => () => {},
  };
  return { page, emit: (reply: { agents: ChiefAgent[] }) => act(() => emit(reply)) };
}

async function mount(view: string, n: number, landing?: LandingReply, fleet?: FleetReply) {
  const { ChiefViewsPage } = await import("../src/pages/chief-views/ChiefViewsPage");
  const { CHIEF_VIEWS } = await import("../src/pages/chief-views/registry");
  const { ChiefViewsStore } = await import("../src/pages/chief-views/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/chief-views/generated/strings.json")).default;
  const strings = createStrings(table, ["en"]);
  const { page, emit } = client(agents(n), landing, fleet);
  const store = new ChiefViewsStore(page, CHIEF_VIEWS, {
    layout: { enabled: [view], main: view },
    persist: false,
  });
  act(() => root?.unmount());
  rowRenders.clear();
  root = createRoot(host);
  await act(async () => {
    root!.render(<ChiefViewsPage store={store} strings={strings} />);
    await store.start();
  });
  await act(async () => {
    await Promise.resolve();
  });
  return { emit, store };
}

for (const n of [100, 1_000]) {
  test(`a minute passing draws none of ${n} agent rows, only the stamps whose words changed`, async () => {
    jest.useFakeTimers({ now: NOW });
    try {
      await mount("where-is-everybody", n);
      expect(host.querySelectorAll(".cv-row").length).toBe(n);
      const stamp = () =>
        [...host.querySelectorAll(".cv-row")]
          .find((row) => row.querySelector(".cv-row-title")?.textContent === "Agent 1 on #40001")
          ?.querySelector(".cv-ago")?.textContent;
      expect(stamp()).toBe("1m");
      rowRenders.reset();
      await act(async () => void jest.advanceTimersByTime(60_000));
      expect(rowRenders.count("AgentRow")).toBe(0);
      // Stamps under an hour old changed their words; "2h" and "3h" ones did not wake.
      expect(rowRenders.count("AgoStamp")).toBeLessThan(n);
      expect(rowRenders.count("AgoStamp")).toBeGreaterThan(0);
      expect(stamp()).toBe("2m");
    } finally {
      jest.useRealTimers();
    }
  });

  test(`a stream event that changes one of ${n} agents draws that agent's row alone`, async () => {
    const { emit } = await mount("where-is-everybody", n);
    rowRenders.reset();
    emit({ agents: agents(n, (index) => (index === 5 ? "Running the tests" : "Working")) });
    expect(rowRenders.count("AgentRow")).toBe(1);
    expect(host.textContent).toContain("Running the tests");
  });
}

test("on the board, one agent's change draws its card alone, not the pull request cards beside it", async () => {
  const merged = Array.from({ length: 50 }, (_, index) => ({
    number: 40_000 + index,
    title: `PR ${index}`,
    url: `https://example.invalid/${index}`,
    labels: [],
    mergedAt: new Date(Date.now() - 60_000).toISOString(),
  }));
  const { emit } = await mount("agent-board", 100, { repo: "r", base: "b", open: [], merged });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(host.querySelectorAll(".cv-pr-row").length).toBe(50);
  rowRenders.reset();
  emit({ agents: agents(100, (index) => (index === 70 ? "Rebasing" : "Working")) });
  expect(rowRenders.count("AgentRow")).toBe(1);
  expect(rowRenders.count("PRCardRow")).toBe(0);
  // Agent 3 works on #40003: its card's owner chips change with it.
  rowRenders.reset();
  emit({ agents: agents(100, (index) => (index === 3 ? "Rebasing" : "Working")) });
  expect(rowRenders.count("PRCardRow")).toBe(1);
});

test("a Refresh whose replies did not change draws no agent row, card, event or machine on any view", async () => {
  const merged = Array.from({ length: 30 }, (_, index) => ({
    number: 40_000 + index,
    title: `PR ${index}`,
    url: `https://example.invalid/${index}`,
    labels: ["ready-to-land"],
    mergedAt: new Date(Date.now() - 60_000).toISOString(),
  }));
  const landing: LandingReply = { repo: "r", base: "b", open: merged.slice(0, 10), merged };
  const fleet: FleetReply = {
    machines: Array.from({ length: 20 }, (_, index) => ({
      host: `m${index}.example`,
      load: index,
      ncpu: 8,
      runnersBusy: 1,
      runnersOnline: 2,
    })),
    queued: 0,
    prs: merged.map((pr) => ({ number: pr.number, title: pr.title, branch: `b-${pr.number}`, status: "success" })),
  };
  const settle = () =>
    act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  for (const view of ["where-is-everybody", "agent-board", "landing", "timeline", "fleet"]) {
    const { store } = await mount(view, 100, landing, fleet);
    await settle();
    const counted = ["AgentRow", "PRCardRow", "EventRow", "MachineRow"];
    const drawn = () => Object.fromEntries(counted.map((name) => [name, rowRenders.count(name)]));
    expect(Object.values(drawn()).some((count) => count > 0)).toBe(true);
    rowRenders.reset();
    act(() => store.refresh(["fleet", "landing"]));
    await settle();
    expect({ view, ...drawn() } as Record<string, unknown>).toEqual({
      view,
      AgentRow: 0,
      PRCardRow: 0,
      EventRow: 0,
      MachineRow: 0,
    });
  }
});
