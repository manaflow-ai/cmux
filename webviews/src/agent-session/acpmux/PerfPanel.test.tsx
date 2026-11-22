// The Inspector's Perf tab (PerfPanel.tsx): its switch follows the daemon's watch, it reads the
// watch only while it is on and open, and it draws notes newest first, spans as a waterfall against
// their budget and the data meter's hot zones.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PerfPanel } from "./PerfPanel";
import { PerfReporter, type PerfReporterEnv } from "./perfReporter";
import { AcpmuxPerf } from "./perf";
import { AcpWireLog } from "./wire";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// A reporter that registers nothing real (the tab tells it the watch's state).
function quietReporter(): PerfReporter {
  const env: PerfReporterEnv = {
    perf: new AcpmuxPerf(),
    wire: new AcpWireLog(),
    now: () => 0,
    wall: () => 0,
    every: () => 1,
    stopEvery: () => undefined,
    frame: () => 1,
    cancelFrame: () => undefined,
    observe: () => undefined,
  };
  return new PerfReporter(env);
}

const EVENTS = [
  { kind: "note", seq: 1, at: 1_000, text: "older note" },
  {
    kind: "span",
    seq: 2,
    at: 2_000,
    name: "new chat",
    ms: 4_000,
    budgetMs: 3_000,
    over: true,
    parts: [
      { name: "handshake", startMs: 0, ms: 1_000 },
      { name: "first token", startMs: 1_000, ms: 3_000 },
    ],
  },
  {
    kind: "meter",
    seq: 3,
    at: 3_000,
    top: [
      {
        channel: "daemon-ipc",
        label: "session/list",
        bytesPerMinute: 2 * 1024 * 1024,
        bytes: 3_000_000,
        count: 4,
        largest: 900,
      },
    ],
  },
  { kind: "note", seq: 4, at: 4_000, text: "newer note", quietedBefore: 2 },
];

function fakeDaemon(initiallyOn: boolean) {
  const sent: Record<string, unknown>[] = [];
  let on = initiallyOn;
  let reads = 0;
  const send = async (params: Record<string, unknown>): Promise<unknown> => {
    sent.push(params);
    switch (params.op) {
      case "status":
        return on ? { on, seq: 4 } : { on };
      case "on":
      case "off":
        on = params.op === "on";
        return on ? { on, seq: 0 } : { on };
      case "read":
        reads += 1;
        // The first read answers at once; the next waits, as a long read with nothing new does.
        if (reads === 1) return { on, events: EVENTS, seq: 4 };
        return new Promise(() => undefined);
      case "snapshot":
        return { on, events: EVENTS, meter: [] };
    }
    return {};
  };
  return { send, sent };
}

async function render(container: HTMLElement, element: React.ReactElement) {
  root ??= createRoot(container);
  await act(async () => root!.render(element));
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("off: the switch is off, nothing is read, and the hint says what turning it on does", async () => {
  const container = installDom();
  const daemon = fakeDaemon(false);
  await render(container, <PerfPanel send={daemon.send} reporter={quietReporter()} />);
  expect(daemon.sent).toEqual([{ op: "status" }]);
  expect(container.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("false");
  expect(container.querySelector(".acpmux-inspector-perf-empty")).not.toBeNull();
  expect(container.querySelector(".acpmux-inspector-perf-body")).toBeNull();
});

test("on: notes newest first, a span over budget as a waterfall, the hot zones", async () => {
  const container = installDom();
  const daemon = fakeDaemon(true);
  const reporter = quietReporter();
  await render(container, <PerfPanel send={daemon.send} reporter={reporter} />);
  expect(reporter.on).toBe(true);
  expect(daemon.sent.map((params) => params.op)).toEqual(["status", "read", "read"]);
  expect(daemon.sent[1]).toEqual({ op: "read", after: 0, limit: 500, waitMs: 20_000 });
  expect(daemon.sent[2]!.after).toBe(4);
  const notes = [...container.querySelectorAll(".acpmux-inspector-perf-notes li")].map((li) => li.textContent);
  expect(notes[0]).toContain("newer note");
  expect(notes[1]).toContain("older note");
  const span = container.querySelector(".acpmux-inspector-perf-span")!;
  expect(span.getAttribute("data-over")).toBe("true");
  const bars = [...span.querySelectorAll<HTMLElement>(".acpmux-inspector-perf-bar")];
  expect(bars.map((bar) => [bar.style.left, bar.style.width])).toEqual([
    ["0%", "25%"],
    ["25%", "75%"],
  ]);
  expect(span.querySelector<HTMLElement>(".acpmux-inspector-perf-budget")!.style.left).toBe("75%");
  const cells = [...container.querySelectorAll(".acpmux-inspector-perf-meter tbody td")].map((td) => td.textContent);
  expect(cells).toEqual(["daemon-ipc", "session/list", "2.0 MB", "2.9 MB", "900 B"]);
});

test("the switch turns the watch off, and the reporter with it", async () => {
  const container = installDom();
  const daemon = fakeDaemon(true);
  const reporter = quietReporter();
  await render(container, <PerfPanel send={daemon.send} reporter={reporter} />);
  await act(async () => {
    container.querySelector<HTMLElement>('[role="switch"]')!.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(daemon.sent.at(-1)).toEqual({ op: "off" });
  expect(reporter.on).toBe(false);
  expect(container.querySelector(".acpmux-inspector-perf-body")).toBeNull();
});

test("closing the tab stops the read loop", async () => {
  const container = installDom();
  let release: ((value: unknown) => void) | undefined;
  const sent: string[] = [];
  const send = async (params: Record<string, unknown>): Promise<unknown> => {
    sent.push(String(params.op));
    if (params.op === "status") return { on: true, seq: 0 };
    return new Promise((resolve) => (release = resolve));
  };
  await render(container, <PerfPanel send={send} reporter={quietReporter()} />);
  expect(sent).toEqual(["status", "read"]);
  await act(async () => root!.unmount());
  root = undefined;
  release!({ on: true, events: [], seq: 0 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(sent).toEqual(["status", "read"]);
});

test("Copy diagnosis copies the daemon's snapshot with the page's own state", async () => {
  const container = installDom();
  const daemon = fakeDaemon(true);
  let copied = "";
  await render(
    container,
    <PerfPanel
      send={daemon.send}
      reporter={quietReporter()}
      page={() => ({ renders: { Row: 3 } })}
      copy={async (text) => {
        copied = text;
        return true;
      }}
    />,
  );
  const button = [...container.querySelectorAll("button")].find((each) => each.textContent === "Copy diagnosis")!;
  await act(async () => {
    button.click();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const diagnosis = JSON.parse(copied);
  expect(diagnosis.type).toBe("cmux-perf-diagnosis");
  expect(diagnosis.snapshot.events.length).toBe(4);
  expect(diagnosis.page).toEqual({ renders: { Row: 3 } });
  expect(container.textContent).toContain("Diagnosis copied");
});
