// l10n-allow-file: test fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderBridgeScript } from "../src/agent-session/acpmux/conversation/renderFrameShell";
import { renderStreamScript } from "../src/agent-session/acpmux/conversation/renderStreamRuntime";
import { renderChartSource } from "../src/agent-session/acpmux/conversation/renderChart";
import { RENDER_KIT_CSS } from "../src/agent-session/acpmux/conversation/renderKit";

function frame(kit = true) {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const win = dom.window;
  const messages: any[] = [];
  const parent = { postMessage: (data: unknown) => messages.push(data) };
  const animations: Element[] = [];
  const observers: { draw?: () => void; disconnected: boolean }[] = [];
  Object.defineProperty(win, "parent", { value: parent });
  Object.assign(win, {
    ResizeObserver: class {
      disconnected = false;
      constructor() {
        observers.push(this);
      }
      observe() {}
      unobserve() {}
      disconnect() {
        this.disconnected = true;
      }
    },
    matchMedia: () => ({ matches: false }),
  });
  win.Element.prototype.animate = function () {
    animations.push(this);
    return {} as Animation;
  };
  win.eval(renderBridgeScript("light", ":where(:root){--cmux-accent:green}").slice(8, -9));
  win.eval(renderStreamScript().slice(8, -9));
  const send = (data: unknown) =>
    win.dispatchEvent(new win.MessageEvent("message", { source: parent as unknown as Window, data }));
  send({ type: "cmux-render-kit", enabled: kit });
  const html = (html: string, done = false) => send({ type: "cmux-render-stream", html, done });
  return { win, messages, send, html, animations, observers, cmux: (win as any).cmux };
}

test("kit installs before content, off omits it, and agent CSS wins", () => {
  for (const enabled of [true, false]) {
    const f = frame(enabled);
    try {
      expect(f.win.document.body.children.length).toBe(0);
      expect(f.win.document.head.textContent!.includes(".segmented")).toBe(enabled);
      expect(typeof f.cmux.chart).toBe(enabled ? "function" : "undefined");
      f.html("<style>h2{font-size:31px;color:rgb(100, 20, 30)}</style><h2>Native</h2>");
      expect(f.win.getComputedStyle(f.win.document.querySelector("h2")!).fontSize).toBe("31px");
      expect(f.win.getComputedStyle(f.win.document.querySelector("h2")!).color).toBe("rgb(100, 20, 30)");
    } finally {
      f.win.close();
    }
  }
  expect(RENDER_KIT_CSS.length).toBeLessThan(8192);
  expect(renderChartSource().length).toBeLessThan(7168);
});

test.each(["line", "area", "bar", "donut", "pie"])("chart %s draws SVG and safe labels", (type) => {
  const f = frame();
  try {
    const el = f.win.document.createElement("div");
    f.win.document.body.append(el);
    f.cmux.chart(el, {
      type,
      height: 240,
      labels: ["<img onerror=x>", "Tue"],
      series: [{ name: "Builds", values: [5, 12] }],
    });
    expect(el.querySelector("svg")?.getAttribute("height")).toBe("240");
    expect(
      el.querySelectorAll(
        type === "bar" ? "rect" : type === "pie" || type === "donut" ? "path" : 'path[style*="stroke:"]',
      ).length,
    ).toBeGreaterThan(0);
    expect(el.querySelector("img")).toBeNull();
    f.send({ type: "cmux-render-theme", theme: "dark", css: ":root{--cmux-chart-1:red}" });
    expect(el.querySelector("svg")).not.toBeNull();
    const dispose = f.cmux.chart(el, { type, labels: ["A"], series: [{ values: [10] }] });
    dispose();
    expect(el.children.length).toBe(0);
  } finally {
    f.win.close();
  }
});

test("empty and bad data never throws, including malformed declarations", () => {
  const f = frame();
  try {
    f.html('<div id="c" data-cmux-chart="bad json"></div>', true);
    for (const options of [
      null,
      {},
      { labels: [], series: [] },
      { labels: ["A", "B"], series: [null, {}, { values: [NaN, Infinity] }] },
    ])
      expect(() => f.cmux.chart("#c", options)).not.toThrow();
    expect(() => f.cmux.chart("#absent", {})).not.toThrow();
    expect(f.win.document.querySelector("svg")).not.toBeNull();
  } finally {
    f.win.close();
  }
});

test("declarations draw on close and buttons request the confirm bridge during streaming", () => {
  const f = frame();
  try {
    const html = `<div data-cmux-chart='{"type":"bar","labels":["A"],"series":[{"values":[1]}]}'></div><button data-cmux-prompt="Investigate"><strong>Go</strong></button><button data-cmux-prefill="Draft">Edit</button>`;
    f.html(html);
    expect(f.win.document.querySelector("svg")).toBeNull();
    f.win.document.querySelector<HTMLElement>("strong")!.click();
    f.win.document.querySelectorAll<HTMLButtonElement>("button")[1]!.click();
    expect(f.messages.filter((m) => m.type === "cmux-render-request").map((m) => [m.method, m.params.text])).toEqual([
      ["sendPrompt", "Investigate"],
      ["prefill", "Draft"],
    ]);
    f.html(html, true);
    expect(f.win.document.querySelector("svg")).not.toBeNull();
  } finally {
    f.win.close();
  }
});

test("only appended nodes animate, respecting reduced motion", () => {
  const f = frame();
  try {
    f.html("<p>First</p>");
    f.html("<p>First grows</p>");
    expect(f.animations.length).toBe(1);
    f.html("<h2>Replacement</h2>");
    expect(f.animations.length).toBe(1);
    f.html("<h2>Replacement</h2><p>Added</p>");
    expect(f.animations.length).toBe(2);
    (f.win as any).matchMedia = () => ({ matches: true });
    f.html("<h2>Replacement</h2><p>Added</p><p>Reduced</p>");
    expect(f.animations.length).toBe(2);
  } finally {
    f.win.close();
  }
});

test("errors and rejections report only after activation and are bounded", () => {
  const f = frame();
  try {
    const error = () => f.win.dispatchEvent(new f.win.ErrorEvent("error", { message: "Broken chart" }));
    error();
    expect(f.messages.some((m) => m.type === "cmux-render-error")).toBe(false);
    f.html("<p>Done</p>", true);
    error();
    const rejection = new f.win.Event("unhandledrejection");
    Object.assign(rejection, { reason: new Error("x".repeat(1000)) });
    f.win.dispatchEvent(rejection);
    expect(f.messages.filter((m) => m.type === "cmux-render-error").map((m) => m.error)).toEqual([
      "Broken chart",
      "x".repeat(500),
    ]);
  } finally {
    f.win.close();
  }
});

test.each(["cancelled", "rate limited", "replaced"])(
  "bridge rejection %s is not an agent render error",
  async (message) => {
    const f = frame();
    try {
      f.html("<p>Done</p>", true);
      const rejection = f.cmux.sendPrompt("Draft").catch((error: unknown) => error);
      const request = f.messages.find((m) => m.type === "cmux-render-request");
      f.send({ type: "cmux-render-reply", id: request.id, ok: false, error: message });
      const reason = await rejection;
      expect(reason.message).toBe(message);
      const event = new f.win.Event("unhandledrejection");
      Object.assign(event, { reason });
      f.win.dispatchEvent(event);
      expect(f.messages.filter((m) => m.type === "cmux-render-error")).toEqual([]);
      f.win.dispatchEvent(new f.win.ErrorEvent("error", { message, error: new Error(message) }));
      expect(f.messages.at(-1)?.error).toBe(message);
    } finally {
      f.win.close();
    }
  },
);

test("benign resize and opaque script errors are filtered, detailed errors survive", () => {
  const f = frame();
  try {
    f.html("<p>Done</p>", true);
    for (const message of [
      "ResizeObserver loop limit exceeded",
      "ResizeObserver loop completed with undelivered notifications.",
      "Script error.",
      "",
      "   ",
    ])
      f.win.dispatchEvent(new f.win.ErrorEvent("error", { message }));
    expect(f.messages.filter((m) => m.type === "cmux-render-error")).toEqual([]);
    f.win.dispatchEvent(
      new f.win.ErrorEvent("error", { message: "Script error.", error: new Error("Actual failure") }),
    );
    expect(f.messages.at(-1)?.error).toBe("Actual failure");
  } finally {
    f.win.close();
  }
});

test("disposing an older chart preserves the replacement and its theme redraw", () => {
  const f = frame();
  try {
    f.html('<div id="c"></div>');
    const el = f.win.document.querySelector("#c")!;
    const old = f.cmux.chart(el, { labels: ["A"], series: [{ name: "Old", values: [1] }] });
    f.cmux.chart(el, { labels: ["A"], series: [{ name: "New", values: [2] }] });
    const svg = el.querySelector("svg");
    old();
    expect(el.querySelector("svg") === svg).toBe(true);
    f.send({ type: "cmux-render-theme", theme: "dark", css: "" });
    expect(el.querySelector("svg") === svg).toBe(false);
    expect(el.textContent).toContain("New");
    expect(f.observers.at(-1)?.disconnected).toBe(false);
  } finally {
    f.win.close();
  }
});

test.each(["line", "area", "bar"])("%s keeps gaps for missing and nonfinite values and a dash in tooltips", (type) => {
  const f = frame();
  try {
    f.html('<div id="c"></div>');
    const el = f.win.document.querySelector("#c")!;
    f.cmux.chart(el, {
      type,
      labels: ["A", "B", "C", "D", "E", "F"],
      series: [{ name: "Builds", values: [2, NaN, 4, null, 0] }],
    });
    if (type === "bar") expect(el.querySelectorAll("rect").length).toBe(4);
    else {
      const line = el.querySelector('path[stroke],path[style*="stroke:"]')!;
      expect(line.getAttribute("d")?.match(/M/g)?.length).toBe(3);
      if (type === "area") expect(el.querySelectorAll("path").length).toBe(4);
    }
    const svg = el.querySelector("svg")!;
    for (const [index, value] of [
      [1, "-"],
      [3, "-"],
      [4, "0"],
      [5, "-"],
    ] as const) {
      svg.dispatchEvent(new f.win.MouseEvent("pointermove", { clientX: 28 + ((488 - 28) / 6) * (index + 0.5) }));
      expect(el.querySelector('g[visibility="visible"]')?.textContent).toContain("Builds: " + value);
    }
  } finally {
    f.win.close();
  }
});
