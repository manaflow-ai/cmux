// The Chief view gallery (cmux.chief-views) over its mock host: the pure model (Lanes order,
// machine groups, the PR an agent works on, landing lanes, the board, today's timeline, fleet
// totals), the store's layout (one view on at first, toggle, pane / split / sidebar, what it
// keeps in localStorage), the reads it makes only for the views shown, the page rendering each
// view, and every string the page uses in every locale.
import { afterAll, beforeAll, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LOCALES } from "../scripts/pages/gen-strings.mjs";
import type { PageClient } from "../src/pages/shared/pageClient";
import {
  FIXTURE_NOW,
  MockChiefViewsProvider,
  mockAgents,
  mockFleet,
  mockLanding,
} from "../src/pages/chief-views/mockProvider";
import {
  agentPR,
  agentsOnHost,
  boardColumns,
  branchPRs,
  byMachine,
  ciKind,
  fleetTotals,
  folderName,
  landingLanes,
  startOfDay,
  stateCounts,
  timeline,
} from "../src/pages/chief-views/model";
import { CHIEF_VIEWS, viewById } from "../src/pages/chief-views/registry";
import { ChiefViewsStore, LAYOUT_KEY, defaultLayout } from "../src/pages/chief-views/store";
import { ChiefViewsOps, type ChiefAgent } from "../src/pages/chief-views/types";

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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const agent = (over: Partial<ChiefAgent>): ChiefAgent => ({
  id: "a",
  kind: "chat",
  name: "a",
  title: "A",
  machine: "local",
  state: "working",
  ...over,
});

const today = startOfDay(FIXTURE_NOW);

test("the registry has five views, only the first on by default, each with a placement", () => {
  expect(CHIEF_VIEWS.map((view) => view.id)).toEqual([
    "where-is-everybody",
    "agent-board",
    "fleet",
    "landing",
    "timeline",
  ]);
  expect(CHIEF_VIEWS.filter((view) => view.defaultOn).map((view) => view.id)).toEqual(["where-is-everybody"]);
  for (const view of CHIEF_VIEWS) expect(["pane", "split", "sidebar"]).toContain(view.defaultPlacement);
  expect(viewById("fleet")?.needs).toContain("fleet");
  expect(viewById("nope")).toBeUndefined();
});

test("machines group this Mac first, then by name; each machine in the Lanes order", () => {
  const groups = byMachine([
    agent({ id: "1", machine: "peer/z", machineName: "zeta", state: "working", since: 5 }),
    agent({ id: "2", machine: "local", state: "working", since: 10 }),
    agent({ id: "3", machine: "local", state: "waiting", since: 1 }),
    agent({ id: "4", machine: "peer/b", machineName: "beta", state: "failed" }),
  ]);
  expect(groups.map((group) => group.id)).toEqual(["local", "peer/b", "peer/z"]);
  expect(groups[0]!.agents.map((a) => a.id)).toEqual(["3", "2"]);
  expect(groups[0]!.attention).toBe(1);
  expect(groups[1]!.attention).toBe(1);
  // The filter matches title, task, folder and machine name.
  expect(byMachine(mockAgents(), "big-red").flatMap((group) => group.agents).length).toBeGreaterThan(0);
  expect(byMachine(mockAgents(), "no such thing")).toEqual([]);
});

test("an agent's PR comes from its branch first, then #N, pull/N or pr-N in its text", () => {
  const known = branchPRs([{ number: 41000, title: "x", branch: "feature-x", status: "running" }]);
  expect(agentPR(agent({ branch: "feature-x", title: "see #123" }), known)).toBe(41000);
  expect(agentPR(agent({ title: "Fix it (#22630)" }))).toBe(22630);
  expect(agentPR(agent({ task: "reading github.com/o/r/pull/9876" }))).toBe(9876);
  expect(agentPR(agent({ branch: "pr-4321-rebase" }))).toBe(4321);
  // Two digits are an issue reference or a list number, not a PR here.
  expect(agentPR(agent({ title: "step #12" }))).toBeUndefined();
});

test("folders show their last two components; states count; CI words map to four kinds", () => {
  expect(folderName("/Users/leo/Projects/work-needsyou/cmux/")).toBe("work-needsyou/cmux");
  expect(folderName("cmux")).toBe("cmux");
  expect(folderName(undefined)).toBeUndefined();
  expect(stateCounts(mockAgents())).toMatchObject({ working: 4, waiting: 2, failed: 1, idle: 2 });
  expect(["failed", "passed", "running", "queued", "odd"].map(ciKind)).toEqual([
    "red",
    "green",
    "running",
    "queued",
    undefined,
  ]);
});

test("landing lanes: red CI wins over the label, merged keeps today's only, newest first", () => {
  const lanes = landingLanes(mockLanding(), mockAgents(), mockFleet().prs, today);
  expect(lanes.ready.map((pr) => pr.number)).toEqual([22618]);
  // #22604 carries ready-to-land, but the dashboard says its CI failed.
  expect(lanes.red.map((pr) => pr.number)).toEqual([22604]);
  expect(lanes.open.map((pr) => pr.number)).toEqual([22630, 22597]);
  expect(lanes.merged.map((pr) => pr.number)).toEqual([22613, 22591, 22055]);
  expect(lanes.open[0]!.owners.map((owner) => owner.id)).toContain("s-needsyou");

  const board = boardColumns(mockAgents(), lanes);
  expect(board.working.every((a) => a.state === "working")).toBe(true);
  expect(board.needsYou.every((a) => a.state === "waiting" || a.state === "failed")).toBe(true);
  expect(board.needsYou[0]!.state).toBe("failed");
  expect(board.ready).toBe(lanes.ready);
  expect(board.landed).toBe(lanes.merged);
});

test("the timeline holds today's events only, newest first", () => {
  const events = timeline(mockAgents(), mockLanding(), today);
  expect(events.length).toBeGreaterThan(5);
  for (let i = 1; i < events.length; i++) expect(events[i - 1]!.at).toBeGreaterThanOrEqual(events[i]!.at);
  expect(events.every((event) => event.at >= today)).toBe(true);
  // The PR opened 26 hours ago is yesterday's.
  expect(events.some((event) => event.kind === "opened" && event.pr?.number === 22604)).toBe(false);
  const kinds = new Set(events.map((event) => event.kind));
  for (const kind of ["spawned", "waiting", "failed", "merged", "opened"]) expect(kinds.has(kind as never)).toBe(true);
  // A working agent has no state event, only its start.
  const working = events.filter((event) => event.agent?.state === "working");
  expect(working.every((event) => event.kind === "spawned")).toBe(true);
});

test("fleet totals and agents per host", () => {
  const fleet = mockFleet();
  const totals = fleetTotals(fleet.machines);
  expect(totals).toMatchObject({ busy: 14, online: 21, unreachable: 1, machines: 6 });
  expect(agentsOnHost(mockAgents(), "cmux16.tail.example.ts.net")).toBe(1);
});

test("the store starts with the first view only, toggles, places and keeps the layout", () => {
  localStorage.removeItem(LAYOUT_KEY);
  const store = new ChiefViewsStore(new MockChiefViewsProvider(), CHIEF_VIEWS);
  expect(store.getSnapshot().layout).toEqual(defaultLayout(CHIEF_VIEWS));
  expect(store.getSnapshot().layout).toEqual({ enabled: ["where-is-everybody"], main: "where-is-everybody" });
  expect(store.getSnapshot().catalog).toBe(false);

  store.show("fleet", "split");
  expect(store.getSnapshot().layout).toEqual({
    enabled: ["where-is-everybody", "fleet"],
    main: "where-is-everybody",
    side: { id: "fleet", placement: "split" },
  });
  // Opening the side view in the pane swaps the two.
  store.show("fleet", "pane");
  expect(store.getSnapshot().layout).toMatchObject({ main: "fleet", side: { id: "where-is-everybody" } });
  store.closeSide();
  expect(store.getSnapshot().layout.side).toBeUndefined();

  store.toggle("timeline");
  expect(store.getSnapshot().layout.enabled).toEqual(["where-is-everybody", "fleet", "timeline"]);
  // Turning the pane's view off moves another one in.
  store.toggle("fleet");
  expect(store.getSnapshot().layout).toMatchObject({
    enabled: ["where-is-everybody", "timeline"],
    main: "where-is-everybody",
  });

  // A new page reads the same layout back; unknown ids and a bad side are dropped.
  expect(new ChiefViewsStore(null, CHIEF_VIEWS).getSnapshot().layout).toEqual(store.getSnapshot().layout);
  localStorage.setItem(
    LAYOUT_KEY,
    JSON.stringify({ enabled: ["gone", "landing"], main: "gone", side: { id: "landing", placement: "float" } }),
  );
  expect(new ChiefViewsStore(null, CHIEF_VIEWS).getSnapshot().layout).toEqual({
    enabled: ["landing"],
    main: "landing",
  });
  localStorage.setItem(LAYOUT_KEY, "{not json");
  expect(new ChiefViewsStore(null, CHIEF_VIEWS).getSnapshot().layout).toEqual(defaultLayout(CHIEF_VIEWS));

  // Every view off: the gallery opens by itself.
  localStorage.setItem(LAYOUT_KEY, JSON.stringify({ enabled: [] }));
  expect(new ChiefViewsStore(null, CHIEF_VIEWS).getSnapshot().catalog).toBe(true);
  localStorage.removeItem(LAYOUT_KEY);
});

test("the store reads fleet and landing only when a view needs them, and says when fleet is unset", async () => {
  const calls: string[] = [];
  const mock = new MockChiefViewsProvider("fleet-unset");
  const client: PageClient = {
    call: (op, params) => {
      calls.push(op);
      return mock.call(op, params);
    },
    subscribe: () => mock.subscribe(),
    handle: (op, handler) => mock.handle(op, handler),
  };
  const store = new ChiefViewsStore(client, CHIEF_VIEWS, { persist: false });
  await store.start();
  expect(store.getSnapshot().agents).toMatchObject({ status: "ready" });
  expect(calls).toEqual([ChiefViewsOps.agents]);

  store.need(["agents"]);
  expect(calls).toEqual([ChiefViewsOps.agents]);
  store.need(["agents", "fleet"]);
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(store.getSnapshot().fleet).toMatchObject({ status: "unavailable", configured: false });

  expect(await store.setFleetURL(" https://ci.example.test/ ")).toBe(true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(store.getSnapshot().fleet).toMatchObject({ status: "ready" });
  // Read once; asking again does not read again, Refresh does.
  const fleetReads = () => calls.filter((op) => op === ChiefViewsOps.fleet).length;
  const before = fleetReads();
  store.need(["fleet"]);
  expect(fleetReads()).toBe(before);
  store.refresh(["fleet"]);
  expect(fleetReads()).toBe(before + 1);
  expect(calls).not.toContain(ChiefViewsOps.landing);
});

test("with no host the store says agents are unavailable", async () => {
  const store = new ChiefViewsStore(null, CHIEF_VIEWS, { persist: false });
  await store.start();
  expect(store.getSnapshot()).toMatchObject({ offline: true, agents: { status: "unavailable" } });
});

test("the page renders each view, the dots and the gallery over the mock host", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChiefViewsPage } = await import("../src/pages/chief-views/ChiefViewsPage");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/chief-views/generated/strings.json")).default;
  const strings = createStrings(table);
  const all = CHIEF_VIEWS.map((view) => view.id);
  const render = async (layout: { enabled: string[]; main?: string }, catalog = false) => {
    const store = new ChiefViewsStore(new MockChiefViewsProvider(), CHIEF_VIEWS, { layout, catalog, persist: false });
    act(() => root?.unmount());
    root = createRoot(host);
    await act(async () => {
      root!.render(<ChiefViewsPage store={store} strings={strings} now={FIXTURE_NOW} />);
      await store.start();
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    return store;
  };

  await render({ enabled: ["where-is-everybody"], main: "where-is-everybody" });
  expect(host.querySelector(".cv-title")?.textContent).toBe("Where is everybody");
  expect(host.querySelectorAll(".cv-dot").length).toBe(1);
  expect(host.textContent).toContain("Needs-you view: group by decision");
  expect(host.textContent).toContain("#22630");

  await render({ enabled: all, main: "agent-board" });
  expect(host.querySelectorAll(".cv-dot").length).toBe(5);
  expect([...host.querySelectorAll(".cv-column-head")].map((h) => h.firstChild?.textContent)).toEqual([
    "Working",
    "Needs you",
    "Ready to land",
    "Landed today",
  ]);

  await render({ enabled: all, main: "fleet" });
  expect(host.querySelectorAll(".cv-table tbody tr").length).toBe(6);
  expect(host.querySelector(".cv-host-error")?.textContent).toBe("console locked");

  await render({ enabled: all, main: "landing" });
  expect(host.textContent).toContain("Import cards from Arc and Chrome");

  await render({ enabled: all, main: "timeline" });
  expect(host.querySelectorAll("ol li").length).toBeGreaterThan(5);

  const store = await render({ enabled: ["where-is-everybody"], main: "where-is-everybody" }, true);
  expect(host.querySelectorAll('[role="switch"]').length).toBe(5);
  const off = [...host.querySelectorAll('[role="switch"]')].map((el) => el.getAttribute("aria-checked"));
  expect(off).toEqual(["true", "false", "false", "false", "false"]);
  act(() => (host.querySelectorAll('[role="switch"]')[2] as HTMLElement).click());
  expect(store.getSnapshot().layout.enabled).toEqual(["where-is-everybody", "fleet"]);
});

test("every string the page uses exists in every locale, with its placeholders", () => {
  const dir = path.join(import.meta.dir, "../src/pages/chief-views");
  const catalog = JSON.parse(fs.readFileSync(path.join(dir, "Localizable.xcstrings"), "utf8")) as {
    strings: Record<string, { localizations: Record<string, { stringUnit: { value: string } }> }>;
  };
  const sources = [
    ...fs.readdirSync(dir).filter((file) => /\.tsx?$/.test(file) && !file.includes("gallery")),
    ...fs.readdirSync(path.join(dir, "views")).map((file) => `views/${file}`),
  ].map((file) => fs.readFileSync(path.join(dir, file), "utf8"));
  const used = new Set(
    sources.flatMap((source) => [...source.matchAll(/"(chiefViews\.[A-Za-z0-9.]+)"/g)].map((m) => m[1]!)),
  );
  for (const state of ["working", "waiting", "idle", "failed"]) used.add(`chiefViews.state.${state}`);
  for (const kind of ["red", "green", "running", "queued"]) used.add(`chiefViews.ci.${kind}`);
  for (const placement of ["pane", "split", "sidebar"]) used.add(`chiefViews.placement.${placement}`);
  for (const kind of ["spawned", "waiting", "failed", "finished", "opened", "merged"])
    used.add(`chiefViews.timeline.${kind}`);
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
