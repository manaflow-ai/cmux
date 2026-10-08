import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { App } from "../src/optchat-inspector/App";
import { childrenOf, hitRate, lineCuts, nextPath, parseName, segments } from "../src/optchat-inspector/model";
import { ApiStore, bridgeFetcher, fetcherFor, httpFetcher } from "../src/optchat-inspector/store";
import type { TurnPrompt } from "../src/optchat-inspector/types";
import { StoreContext } from "../src/optchat-inspector/useApi";

// The memory inspector page, rendered in jsdom against a fake inspector API (no browser runs).

let root: Root | null = null;
let dom: JSDOM | null = null;
const saved = new Map<string, unknown>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement"])
  saved.set(key, (globalThis as Record<string, unknown>)[key]);

afterEach(async () => {
  if (root) flushSync(() => root?.unmount());
  root = null;
  await new Promise((r) => setTimeout(r, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
});

test("node names, children and the zoom path follow the agent's zoom", () => {
  expect(parseName("64+32")).toEqual({ start: 64, n: 32, level: 5 });
  expect(parseName("3+2")).toBeNull();
  expect(parseName("4+3")).toBeNull();
  expect(childrenOf("64+32")).toEqual(["64+16", "80+16"]);
  expect(childrenOf("7+1")).toBeNull();
  let path = nextPath([], "0+8");
  path = nextPath(path, "4+4");
  path = nextPath(path, "6+2");
  expect(path).toEqual(["0+8", "4+4", "6+2"]);
  expect(nextPath(path, "4+4")).toEqual(["0+8", "4+4"]);
  expect(nextPath(path, "100+1")).toEqual(["100+1"]);
});

test("cache cuts land on line ends and sizes group by prompt part", () => {
  const lines = [
    { name: "0+4", level: 2, start: 0, n: 4, offset: 7, bytes: 10, built: true, text: "a" },
    { name: "4+2", level: 1, start: 4, n: 2, offset: 17, bytes: 10, built: true, text: "b" },
    { name: "6+1", level: 0, start: 6, n: 1, offset: 27, bytes: 10, built: false, text: "c" },
  ];
  const blocks = [
    { role: "system" as const, kind: "instructions" as const, bytes: 100, cache: "harness" as const },
    { role: "system" as const, kind: "view" as const, view_start: 0, bytes: 17, cache: "harness" as const },
    { role: "user" as const, kind: "view" as const, view_start: 17, bytes: 10, cache: "ours" as const },
    { role: "user" as const, kind: "view" as const, view_start: 27, bytes: 10, cache: "none" as const },
    { role: "user" as const, kind: "messages" as const, bytes: 5, cache: "harness" as const },
  ];
  const cuts = lineCuts(lines, [17], [27], blocks, 20);
  expect(cuts[0]).toEqual({ mark: true, grid: false, marker: false, systemEnd: true, unchanged: true });
  expect(cuts[1]).toEqual({ mark: false, grid: true, marker: true, systemEnd: false, unchanged: false });
  expect(segments(blocks).map((s) => [s.tone, s.bytes])).toEqual([
    ["system", 100],
    ["view-system", 17],
    ["view", 20],
    ["messages", 5],
  ]);
  expect(hitRate({ input: 10, cache_read: 30, cache_write: 60, output: 5 })).toBeCloseTo(0.3);
  expect(hitRate({ input: 0, cache_read: 0, cache_write: 0, output: 0 })).toBeNull();
});

test("the store fetches once per URL and reports errors", async () => {
  let calls = 0;
  const store = new ApiStore(async (url) => {
    calls += 1;
    if (url === "/bad") throw new Error("missing or wrong token");
    return { url };
  });
  store.get("/a");
  store.get("/a");
  await new Promise((r) => setTimeout(r, 0));
  expect(calls).toBe(1);
  expect(store.get<{ url: string }>("/a").data?.url).toBe("/a");
  store.get("/bad");
  await new Promise((r) => setTimeout(r, 0));
  expect(store.get("/bad").error).toBe("missing or wrong token");
  // Idle answers beyond the cap are evicted, oldest first; subscribed ones stay.
  const keep = store.subscribe("/a", () => {});
  for (let i = 0; i < 40; i++) store.get(`/n${i}`);
  await new Promise((r) => setTimeout(r, 0));
  const before = calls;
  store.get("/a");
  store.get("/n39");
  await new Promise((r) => setTimeout(r, 0));
  expect(calls).toBe(before);
  store.get("/n0");
  await new Promise((r) => setTimeout(r, 0));
  expect(calls).toBe(before + 1);
  keep();
});

const VIEW = "<chat>\n0+4|summary of the start\n4+2|two messages\n6+1|user: hello\n</chat>";
const now: TurnPrompt = {
  turn: "now",
  layout: "cached",
  exact: { view: true, system: true, messages: true },
  note: null,
  view: { text: VIEW, bytes: VIEW.length, marks: [], grid: [], parts: ["0+4", "4+2", "6+1"] },
  messages: [],
  lines: [
    { name: "0+4", level: 2, start: 0, n: 4, offset: 7, bytes: 25, built: true, text: "summary of the start" },
    { name: "4+2", level: 1, start: 4, n: 2, offset: 32, bytes: 17, built: true, text: "two messages" },
    { name: "6+1", level: 0, start: 6, n: 1, offset: 49, bytes: 16, built: true, text: "user: hello" },
  ],
  system_parts: [{ label: "Who Chief is", explain: "The fixed opening.", text: "You are Chief", bytes: 13 }],
  blocks: [
    { role: "system", kind: "instructions", bytes: 13, cache: "harness" },
    { role: "user", kind: "view", view_start: 0, bytes: VIEW.length, cache: "none" },
    { role: "user", kind: "messages", bytes: 0, cache: "harness" },
  ],
};

function node(name: string) {
  const p = parseName(name)!;
  const kids = childrenOf(name);
  return {
    name,
    level: p.level,
    start: p.start,
    n: p.n,
    end: p.start + p.n,
    built: true,
    bytes: 20,
    text: `text of ${name}`,
    date_first: "2026-10-06 10:00",
    date_last: "2026-10-06 11:00",
    parent: null,
    in_view: name === "0+4",
    zoom: {
      call: `zoom(${p.start}, ${p.n})`,
      answer: kids ? kids.map((k) => `${k}|text of ${k}`).join("\n") : `${p.start}+0|user: message ${p.start}`,
    },
    children: kids?.map((k) => ({
      name: k,
      level: p.level - 1,
      start: parseName(k)!.start,
      n: p.n / 2,
      built: true,
      bytes: 12,
      text: `text of ${k}`,
    })),
    message: kids ? undefined : { id: p.start, kind: "user", text: `message ${p.start} in full`, bytes: 18 },
  };
}

const status = {
  messages: 7,
  view_lines: 3,
  view_bytes: 58,
  budget: 128000,
  unbuilt: 1,
  nodes_built: 9,
  busy: ["6+1"],
  failures: [],
  fatal: null,
  closed: false,
  settled: false,
  settle: { built: 2, total: 3 },
  top_level: 2,
  running_turn: null,
  last_turn: null,
  last_error: null,
  trace_on: true,
  constants: {
    node_bytes: 512,
    view_bytes: 128000,
    marks: [50000, 80000, 100000],
    grid: 4096,
    placeholder: "(not summarized yet: zoom it)",
  },
};

const turnRow = {
  turn: "2026:x:5",
  first: 5,
  ts: Date.UTC(2026, 9, 6, 9),
  status: "ok",
  ms: 4200,
  settle_ms: 300,
  hit_rate: 0.75,
  tools: 2,
  tool_names: { Bash: 2 },
  harness: "claude-sr",
  nodes_before: 3,
  nodes_during: 1,
};

function fakeApi(url: string): unknown {
  const u = new URL(url, "http://127.0.0.1");
  switch (u.pathname) {
    case "/api/status":
      return status;
    case "/api/turns":
      return { turns: [turnRow], more: false };
    case "/api/turn":
      return u.searchParams.get("key") === "now"
        ? now
        : {
            ...now,
            turn: "2026:x:5",
            harness: "claude-sr",
            exact: { view: true, system: false, messages: true },
            note: "The system prompt differs.",
          };
    case "/api/node":
      return node(u.searchParams.get("name")!);
    case "/api/level":
      return { level: Number(u.searchParams.get("l")), per_node: 1, count: 1, from: 0, nodes: [] };
    default:
      throw new Error(`no fake for ${url}`);
  }
}

async function mount() {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url: "http://127.0.0.1:4555/" });
  const g = globalThis as Record<string, unknown>;
  g.window = dom.window;
  g.document = dom.window.document;
  g.navigator = dom.window.navigator;
  g.Element = dom.window.Element;
  g.Node = dom.window.Node;
  g.HTMLElement = dom.window.HTMLElement;
  const store = new ApiStore(async (url) => fakeApi(url));
  root = createRoot(document.getElementById("root")!);
  flushSync(() =>
    root!.render(
      <StoreContext.Provider value={store}>
        <App />
      </StoreContext.Provider>,
    ),
  );
}

async function waitFor(predicate: () => boolean, what: string) {
  const until = Date.now() + 2000;
  while (!predicate()) {
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 0));
  }
}

const text = () => document.body.textContent ?? "";
const click = (el: Element | null | undefined) => flushSync(() => (el as HTMLElement).click());
const button = (label: string) => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === label);

test("a view line zooms like the agent, three hops down to the message", async () => {
  await mount();
  await waitFor(() => text().includes("summary of the start"), "the view");
  expect(text()).toContain("Exact bytes");
  expect(document.querySelectorAll(".lines .line").length).toBe(3);
  expect(document.querySelectorAll("[role=tooltip]").length).toBeGreaterThan(3);
  click(button("0+4"));
  await waitFor(() => text().includes("What the agent gets from zoom(0, 4)"), "the zoom panel");
  expect(text()).toContain("0+2|text of 0+2");
  click(button("Zoom in"));
  await waitFor(() => text().includes("zoom(0, 2)"), "hop 2");
  click(button("Open message"));
  await waitFor(() => text().includes("Message 0 in full"), "the message");
  expect(text()).toContain("message 0 in full");
  expect(text()).toContain("(2 zoom hops)");
  const crumbs = [...document.querySelectorAll(".crumbs button")].map((b) => b.textContent);
  expect(crumbs).toEqual(["The view", "0+4", "0+2"]);
});

test("a timeline row opens that turn's prompt, and Live shows settle progress", async () => {
  await mount();
  await waitFor(() => !!button("Timeline"), "tabs");
  click(button("Timeline"));
  await waitFor(() => document.querySelectorAll("tbody tr").length === 1, "the turn row");
  expect(text()).toContain("75%");
  expect(text()).toContain("Bash ×2");
  click(document.querySelector("tbody tr"));
  await waitFor(() => text().includes("The system prompt differs."), "the turn's prompt");
  expect(text()).toContain("Not exact");
  click(button("Live"));
  await waitFor(() => text().includes("2 of 3 view lines summarized"), "settle progress");
  expect(text()).toContain("Writing 1 summaries: 6+1");
});

test("one code path chosen by origin: the app page asks the bridge, the loopback page uses HTTP", async () => {
  const calls: { op: string; params: unknown }[] = [];
  const call = async (op: string, params: unknown) => {
    calls.push({ op, params });
    return { name: "0+8" };
  };
  expect(fetcherFor("http:", call)).toBe(httpFetcher);
  expect(fetcherFor("cmux-page:", null)).toBe(httpFetcher);
  const bridged = fetcherFor("cmux-page:", call);
  expect(bridged).not.toBe(httpFetcher);
  expect(await bridged("/api/node?name=0%2B8")).toEqual({ name: "0+8" });
  expect(calls).toEqual([{ op: "cmux.chief_inspector.get", params: { path: "/api/node", query: { name: "0+8" } } }]);
  const failing = bridgeFetcher(async () => {
    throw new Error("chief-inspect is for the owner's trusted connection only");
  });
  await expect(failing("/api/status")).rejects.toThrow("owner's trusted connection");
});
