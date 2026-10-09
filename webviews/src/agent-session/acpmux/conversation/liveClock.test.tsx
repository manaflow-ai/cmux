import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// Live elapsed labels (round-1 transcript, goal 7): one shared clock writes the text of every
// running label on second boundaries, without re-rendering React, and sleeps while the pane is hidden.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 20));
  Object.assign(globals, saved);
});

const { act, createElement, Profiler } = await import("react");
const { createRoot } = await import("react-dom/client");
const { watchLive, useLiveText, liveClockStats } = await import("./liveClock");
const { formatDurationIn } = await import("./turns");
const { setPaneLanguage, currentLanguage } = await import("../i18n");
const { WorkingFor } = await import("./WorkingFor");

const wait = (ms: number) => act(() => new Promise((resolve) => setTimeout(resolve, ms)));
const setHidden = (hidden: boolean) => {
  Object.defineProperty(dom.window.document, "hidden", { configurable: true, get: () => hidden });
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};

describe("live clock", () => {
  test("one shared timer serves every live label", async () => {
    const doc = dom.window.document;
    let clock = 10_000;
    const nodes = Array.from({ length: 5 }, () => doc.body.appendChild(doc.createElement("span")));
    const stops = nodes.map((node, index) =>
      watchLive(
        node,
        (now) => `${index}:${now}`,
        () => clock,
      ),
    );
    try {
      expect(liveClockStats.entries()).toBe(5);
      expect(liveClockStats.timers()).toBe(1);
      expect(nodes[3]!.textContent).toBe("3:10000");
      clock = 11_000;
      await wait(1_100);
      expect(nodes.map((node) => node.textContent)).toEqual(["0:11000", "1:11000", "2:11000", "3:11000", "4:11000"]);
    } finally {
      for (const stop of stops) stop();
    }
    expect(liveClockStats.entries()).toBe(0);
    expect(liveClockStats.timers()).toBe(0);
  });

  test("a live label changes its text without re-rendering its component", async () => {
    let clock = 0;
    let renders = 0;
    function Label() {
      const ref = useLiveText(
        (now) => `t=${now}`,
        true,
        () => clock,
      );
      return createElement("span", { ref, className: "live" });
    }
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(createElement(Profiler, { id: "label", onRender: () => (renders += 1) }, createElement(Label))),
      );
      const text = () => dom.window.document.querySelector(".live")?.textContent;
      expect(text()).toBe("t=0");
      clock = 1_000;
      await wait(1_100);
      clock = 2_000;
      await wait(1_100);
      expect(text()).toBe("t=2000");
      expect(renders).toBe(1);
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("the clock sleeps while the pane is hidden and catches up when it shows", async () => {
    const node = dom.window.document.body.appendChild(dom.window.document.createElement("span"));
    let clock = 0;
    const stop = watchLive(
      node,
      (now) => String(now),
      () => clock,
    );
    try {
      setHidden(true);
      expect(liveClockStats.timers()).toBe(0);
      clock = 5_000;
      await wait(1_100);
      expect(node.textContent).toBe("0");
      setHidden(false);
      expect(node.textContent).toBe("5000");
      expect(liveClockStats.timers()).toBe(1);
    } finally {
      stop();
      setHidden(false);
    }
  });
});

describe("localized durations", () => {
  test("durations follow the pane language", () => {
    expect(formatDurationIn(76_000, "en")).toBe("1m 16s");
    expect(formatDurationIn(0, "en")).toBe("0s");
    expect(formatDurationIn(3_723_000, "en")).toBe("1h 2m 3s");
    expect(formatDurationIn(76_000, "ja")).toBe("1分16秒");
  });

  test("the Working line is a translated string", async () => {
    const before = currentLanguage();
    setPaneLanguage("ja");
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(WorkingFor, { row: { id: "w", version: 1, at: 0, kind: "working" }, now: () => 42_000 }),
        ),
      );
      const label = dom.window.document.querySelector(".cv-worked__label")?.textContent ?? "";
      expect(label).toContain("42秒");
      expect(label).not.toContain("Working");
    } finally {
      await act(async () => root.unmount());
      setPaneLanguage(before);
    }
  });
});
