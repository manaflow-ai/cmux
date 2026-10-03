import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { editedCardHeight, layoutConversation, type AcpmuxRow } from "./model";
import { turnView } from "./conversation/turns";

// A silent console: jsdom has no canvas, so text measurement logs and falls back to row estimates.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
/// Every ResizeObserver callback, so a test can report a viewport resize.
const resizeCallbacks: (() => void)[] = [];
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  // Code blocks and edit diffs watch the pane's theme attribute.
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(callback: () => void) {
      resizeCallbacks.push(callback);
    }
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react").then((react) => ({
  act: react.act,
  createElement: react.createElement,
}));
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp, VirtualTranscript } = await import("./App");
const { acpmuxPerf } = await import("./perf");

/// jsdom does no layout: give the transcript scroller a scriptable viewport and scroll offset.
function fakeViewport(size: { width: number; height: number }) {
  const prototype = dom.window.HTMLElement.prototype;
  const offsets = new WeakMap<object, number>();
  const isScroller = (node: HTMLElement) => node.classList.contains("acpmux-scroll");
  Object.defineProperty(prototype, "clientHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? size.height : 0;
    },
  });
  Object.defineProperty(prototype, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? size.width : 0;
    },
  });
  // Like a browser, the offset clamps to the content once it lays out again.
  const contentHeight = (node: HTMLElement) =>
    parseFloat(node.querySelector<HTMLElement>(".acpmux-spacer")?.style.height || "0");
  const maximum = (node: HTMLElement) => Math.max(0, contentHeight(node) - size.height);
  Object.defineProperty(prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? Math.max(contentHeight(this), size.height) : 0;
    },
  });
  Object.defineProperty(prototype, "scrollTop", {
    configurable: true,
    get(this: HTMLElement) {
      const offset = Math.min(offsets.get(this) ?? 0, maximum(this));
      offsets.set(this, offset);
      return offset;
    },
    set(this: HTMLElement, value: number) {
      offsets.set(this, Math.max(0, Math.min(value, maximum(this))));
    },
  });
  return () => {
    for (const key of ["clientHeight", "clientWidth", "scrollHeight", "scrollTop"])
      delete (prototype as unknown as Record<string, unknown>)[key];
  };
}

const rows: AcpmuxRow[] = Array.from({ length: 200 }, (_, index) => ({
  id: `row-${index}`,
  version: 1,
  at: index,
  kind: index % 2 ? "assistant" : "user",
  text: `message ${index}`,
}));

describe("acpmux virtual transcript", () => {
  test("re-renders that keep rows and width reuse the conversation layout", async () => {
    let layouts = 0;
    const addLayout = acpmuxPerf.addLayout.bind(acpmuxPerf);
    acpmuxPerf.enabled = true;
    acpmuxPerf.addLayout = (ms: number) => {
      layouts += 1;
      addLayout(ms);
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const onToggleActivity = () => {};
    try {
      await act(async () =>
        root.render(createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>() })),
      );
      const afterMount = layouts;
      expect(afterMount).toBeGreaterThan(0);
      // A scroll or an expansion toggle re-renders with the same rows and width.
      for (let pass = 0; pass < 5; pass += 1) {
        await act(async () =>
          root.render(
            createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>([`row-${pass}`]) }),
          ),
        );
      }
      expect(layouts).toBe(afterMount);
      // New rows still lay out again.
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [...rows, { id: "row-new", version: 1, at: 999, kind: "assistant", text: "new" }],
            onToggleActivity,
            expanded: new Set<string>(),
          }),
        ),
      );
      expect(layouts).toBeGreaterThan(afterMount);
    } finally {
      await act(async () => root.unmount());
      acpmuxPerf.addLayout = addLayout;
      acpmuxPerf.enabled = false;
    }
  });

  test("a scroll mounts the rows for the next frames in the scroll direction before it paints", async () => {
    const size = { width: 760, height: 600 };
    const restore = fakeViewport(size);
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
        ),
      );
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const totalHeight = parseFloat((dom.window.document.querySelector(".acpmux-spacer") as HTMLElement).style.height);
      expect(scroller.scrollTop).toBe(totalHeight - 600);
      const mountedTops = () =>
        [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) =>
          parseFloat(/translateY\((-?[\d.]+)px\)/.exec(row.style.transform)?.[1] ?? "NaN"),
        );
      // A fling upward: each scroll event moves a viewport and a half. The scroll
      // event commits before the frame paints (no extra animation-frame hop), and
      // rows two steps ahead are already mounted when the next step lands.
      const step = 900;
      for (const top of [totalHeight - 600 - step, totalHeight - 600 - 2 * step]) {
        act(() => {
          scroller.scrollTop = top;
          scroller.dispatchEvent(new dom.window.Event("scroll"));
        });
        expect(Math.min(...mountedTops())).toBeLessThanOrEqual(Math.max(0, top - 2 * step));
        expect(Math.max(...mountedTops())).toBeGreaterThanOrEqual(top);
      }
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  test("a height-only shrink that makes fitting rows overflow opens at the latest row once", async () => {
    const size = { width: 760, height: 10_000 };
    const restore = fakeViewport(size);
    resizeCallbacks.length = 0;
    const root = createRoot(dom.window.document.getElementById("root")!);
    const fewRows = rows.slice(0, 6);
    const render = () =>
      root.render(
        createElement(VirtualTranscript, { rows: fewRows, onToggleActivity: () => {}, expanded: new Set<string>() }),
      );
    const resize = (height: number) =>
      act(async () => {
        size.height = height;
        for (const callback of resizeCallbacks) callback();
      });
    try {
      await act(async () => render());
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const totalHeight = parseFloat((dom.window.document.querySelector(".acpmux-spacer") as HTMLElement).style.height);
      expect(scroller.scrollTop).toBe(0);
      expect(totalHeight).toBeGreaterThan(40);
      await resize(40);
      expect(scroller.scrollTop).toBe(totalHeight - 40);
      // After that one jump a reader who scrolled up stays put through later resizes.
      scroller.scrollTop = 0;
      await resize(30);
      expect(scroller.scrollTop).toBe(0);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux transcript accessibility", () => {
  /// VoiceOver read the transcript as loose text: no list to move through, no speaker per message,
  /// and a turn summary split into five fragments.
  test("the transcript is a feed of articles placed in the whole conversation", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const conversation: AcpmuxRow[] = [
      ...rows,
      { id: "summary", version: 1, at: 999, kind: "turnSummary", durationMs: 3000, toolCount: 2 },
    ];
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: conversation,
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      expect(scroller.getAttribute("role")).toBe("feed");
      expect(scroller.getAttribute("aria-label")).toBe("Transcript");
      const articles = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")];
      expect(articles.length).toBeLessThan(conversation.length);
      for (const article of articles) expect(article.getAttribute("aria-setsize")).toBe(String(conversation.length));
      const last = articles.at(-1)!;
      expect(last.getAttribute("aria-posinset")).toBe(String(conversation.length));
      const mounted = articles.map((article) => ({
        article,
        row: conversation[Number(article.getAttribute("aria-posinset")) - 1]!,
      }));
      expect(mounted.find(({ row }) => row.kind === "user")?.article.getAttribute("aria-label")).toBe("You");
      expect(mounted.find(({ row }) => row.kind === "assistant")?.article.getAttribute("aria-label")).toBe("Agent");
      expect(last.hasAttribute("aria-label")).toBe(false);
      // Without a "Worked for" line above it, the footer says the turn's time and count.
      const summary = last.querySelector(".cv-turn-summary")!;
      expect(summary.childNodes.length).toBe(1);
      expect(summary.textContent).toBe("Worked for 3s");
      // Older history still in acpmux: the conversation's size is unknown.
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: conversation,
            onToggleActivity: () => {},
            expanded: new Set<string>(),
            canLoadOlder: true,
          }),
        ),
      );
      for (const article of dom.window.document.querySelectorAll(".acpmux-row"))
        expect(article.getAttribute("aria-setsize")).toBe("-1");
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A prompt draws as typed in one bubble: no Markdown, so a blank line is
  /// one blank line and not an empty paragraph of two newlines.
  test("a prompt draws as typed in one bubble", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [{ id: "u", version: 1, at: 0, kind: "user", text: "first\n\nsecond" }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const bubbles = [...dom.window.document.querySelectorAll(".cv-user__bubble")];
      expect(bubbles.map((node) => node.textContent)).toEqual(["first\n\nsecond"]);
      expect(bubbles[0]!.querySelector("p")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A nested list drew inline as its source ("order:- Notebook: `3 × 4.50`"), and a numbered
  /// list drew with bullets.
  test("a nested list renders inside its item, and a numbered list keeps its numbers", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const text =
      "- Multiplies qty by price for each order:\n  - Notebook: `3 × 4.50 = 13.50`\n  - Pens: `12 × 0.80 = 9.60`\n- Adds the subtotals.\n\n3. Third\n4. Fourth";
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [{ id: "a", version: 1, at: 0, kind: "assistant", text }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const markdown = dom.window.document.querySelector(".cv-md")!;
      const outer = markdown.querySelector(":scope > ul")!;
      expect([...outer.querySelectorAll(":scope > li")].length).toBe(2);
      const nested = outer.querySelector(":scope > li > ul")!;
      expect([...nested.querySelectorAll(":scope > li")].map((node) => node.textContent)).toEqual([
        "Notebook: 3 × 4.50 = 13.50",
        "Pens: 12 × 0.80 = 9.60",
      ]);
      expect(nested.querySelector("code")?.textContent).toBe("3 × 4.50 = 13.50");
      expect(markdown.textContent).not.toContain("- Notebook");
      const numbered = markdown.querySelector(":scope > ol")!;
      expect(numbered.getAttribute("start")).toBe("3");
      expect(
        [...numbered.querySelectorAll("li")].map((node) => [
          node.querySelector(".cv-li__num")?.textContent,
          node.querySelector(".cv-li__text")?.textContent,
        ]),
      ).toEqual([
        ["3.", "Third"],
        ["4.", "Fourth"],
      ]);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// Rows are at most 760px wide (styles.css), but a wide pane laid them out at its whole width, so
  /// long messages wrapped onto more lines than their rows had room for.
  test("a wide pane lays rows out at the row's capped width", async () => {
    const restore = fakeViewport({ width: 1200, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const long: AcpmuxRow = { id: "long", version: 1, at: 0, kind: "assistant", text: "word ".repeat(120).trim() };
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [long, { id: "next", version: 1, at: 1, kind: "assistant", text: "next" }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const next = dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")[1]!;
      expect(next.style.transform).toBe(`translateY(${layoutConversation([long], 760).heights[0]}px)`);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

/// A seeded generator, so a failing shape reproduces.
function seeded(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

/// Rows of every kind the transcript draws, in random markdown shapes.
function randomConversation(count: number, random: () => number): AcpmuxRow[] {
  const pieces = [
    "A sentence with `code` in it.",
    "## Heading\nText under it.",
    "- one\n- [ ] two\n- three",
    "```\nlet x = 1\n```",
    "> quoted",
    "Line one\nline two",
    "**bold** and [a link](https://example.com)",
  ];
  return Array.from({ length: count }, (_, index) => {
    const pick = random();
    const text = Array.from(
      { length: 1 + Math.floor(random() * 4) },
      () => pieces[Math.floor(random() * pieces.length)]!,
    ).join("\n\n");
    if (pick < 0.35) return { id: `r${index}`, version: 1, at: index, kind: "user", text };
    if (pick < 0.75) return { id: `r${index}`, version: 1, at: index, kind: "assistant", text };
    if (pick < 0.85)
      return {
        id: `r${index}`,
        version: 1,
        at: index,
        kind: "activity",
        toolCount: 2,
        items: [{ kind: "tool", text: "Read a file" }],
      } as AcpmuxRow;
    if (pick < 0.92)
      return {
        id: `r${index}`,
        version: 1,
        at: index,
        kind: "permission",
        permission: { permissionId: `p${index}`, title: "Allow this?", options: [{ id: "allow", name: "Allow" }] },
      } as AcpmuxRow;
    return { id: `r${index}`, version: 1, at: index, kind: "turnSummary", durationMs: 2000, toolCount: 1 };
  });
}

describe("acpmux measured rows", () => {
  /// The layout estimates a row's height before it draws, and some shapes always draw taller
  /// than any estimate (fonts, permission cards, expanded tool output). A row the page has drawn
  /// must be placed by its drawn height, so no row runs under the next one.
  test("drawn rows never overlap, whatever their shape", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const random = seeded(16476);
    const conversation = randomConversation(300, random);
    // jsdom does no layout: each row draws at a height the estimator can't know.
    const drawn = new Map(conversation.map((row) => [row.id, 30 + Math.round(random() * 220)]));
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const index = Number(this.getAttribute("aria-posinset")) - 1;
      const height = this.classList.contains("acpmux-row") ? (drawn.get(conversation[index]?.id ?? "") ?? 0) : 0;
      return {
        x: 0,
        y: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: height,
        width: 0,
        height,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const overlaps = () => {
      const placed = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((article) => ({
          index: Number(article.getAttribute("aria-posinset")) - 1,
          top: Number(/translateY\(([-\d.]+)px\)/.exec(article.style.transform)?.[1]),
        }))
        .sort((a, b) => a.index - b.index);
      const found: string[] = [];
      for (let position = 1; position < placed.length; position += 1) {
        const above = placed[position - 1]!;
        const below = placed[position]!;
        if (below.index !== above.index + 1) continue;
        const bottom = above.top + drawn.get(conversation[above.index]!.id)!;
        if (bottom > below.top + 0.5)
          found.push(
            `${conversation[above.index]!.id} ends at ${bottom}, ${conversation[below.index]!.id} starts at ${below.top}`,
          );
      }
      return found;
    };
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: conversation,
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      expect(overlaps()).toEqual([]);
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      // Opened at the latest row, it stays there as the rows settle to their drawn heights.
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
      for (const top of [0, 4000, 9000]) {
        await act(async () => {
          scroller.scrollTop = top;
          scroller.dispatchEvent(new dom.window.Event("scroll"));
        });
        expect(overlaps()).toEqual([]);
      }
      // A row above the viewport that grows leaves the row at the viewport's top where it is.
      const placed = () =>
        [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")].map((article) => ({
          article,
          index: Number(article.getAttribute("aria-posinset")) - 1,
          top: Number(/translateY\(([-\d.]+)px\)/.exec(article.style.transform)?.[1]),
        }));
      const atTop = () =>
        placed()
          .filter((row) => row.top <= scroller.scrollTop)
          .sort((a, b) => b.top - a.top)[0]!;
      const anchor = atTop();
      const offset = scroller.scrollTop - anchor.top;
      const above = placed()
        .filter((row) => row.index < anchor.index)
        .sort((a, b) => a.index - b.index)[0]!;
      drawn.set(conversation[above.index]!.id, drawn.get(conversation[above.index]!.id)! + 100);
      await act(async () => {
        for (const callback of resizeCallbacks)
          (callback as (entries: { target: Element }[]) => void)([{ target: above.article }]);
      });
      expect(atTop().index).toBe(anchor.index);
      expect(scroller.scrollTop - atTop().top).toBe(offset);
      expect(overlaps()).toEqual([]);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });
  /// A fling mounts rows that have not drawn yet, and each one reports its height once.
  /// Placing it must not measure every row of the conversation again.
  test("a row's drawn height re-places the rows without measuring them again", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    let measures = 0;
    const Plain = Object.assign(() => null, {
      measure: () => {
        measures += 1;
        return 50;
      },
    });
    const registry = { user: Plain, assistant: Plain } as never;
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    let drawnHeight = 0;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height =
        this.classList.contains("acpmux-row") && this.getAttribute("aria-posinset") === "200" ? drawnHeight : 0;
      return {
        x: 0,
        y: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: height,
        width: 0,
        height,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>(), registry }),
        ),
      );
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      const estimated = parseFloat(spacer.style.height);
      const afterOpen = measures;
      drawnHeight = 90;
      const latest = dom.window.document.querySelector<HTMLElement>('.acpmux-row[aria-posinset="200"]')!;
      await act(async () => {
        for (const callback of resizeCallbacks)
          (callback as (entries: { target: Element }[]) => void)([{ target: latest }]);
      });
      expect(parseFloat(spacer.style.height)).toBe(estimated + 40);
      expect(measures).toBe(afterOpen);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });

  /// A permission card or a taller composer shortens the viewport without moving the offset,
  /// so the latest row's end drops below the fold unless the transcript follows it.
  test("at the latest row, a shorter viewport keeps the latest row in view", async () => {
    const size = { width: 760, height: 600 };
    const restore = fakeViewport(size);
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
        ),
      );
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
      size.height = 400;
      await act(async () => {
        for (const callback of resizeCallbacks) (callback as (entries: unknown[]) => void)([]);
      });
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 400);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A reader near the end scrolls up, and before that scroll's event a row below draws shorter.
  /// The offset lands just under the new end without the browser clamping it, so the reader stays.
  test("a small scroll-up at the latest row survives a row below drawing shorter", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    let lastHeight = 120;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height =
        this.classList.contains("acpmux-row") && this.getAttribute("aria-posinset") === "200" ? lastHeight : 0;
      return {
        x: 0,
        y: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: height,
        width: 0,
        height,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const reportLatest = async () => {
      const latest = dom.window.document.querySelector<HTMLElement>('.acpmux-row[aria-posinset="200"]')!;
      await act(async () => {
        for (const callback of resizeCallbacks)
          (callback as (entries: { target: Element }[]) => void)([{ target: latest }]);
      });
    };
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
        ),
      );
      await reportLatest();
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      const end = parseFloat(spacer.style.height) - 600;
      expect(scroller.scrollTop).toBe(end);
      // Up by 10.75px; the latest row then draws 10px shorter, so the new end is 0.75px below the reader.
      scroller.scrollTop = end - 10.75;
      lastHeight -= 10;
      await reportLatest();
      expect(parseFloat(spacer.style.height) - 600).toBe(end - 10);
      expect(scroller.scrollTop).toBe(end - 10.75);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });

  /// Rows that draw shorter than estimated shrink the content under a viewport at the latest row,
  /// and the browser clamps the offset before the layout effect sees it.
  test("opened at the latest row, it stays there as rows draw shorter than estimated", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const conversation: AcpmuxRow[] = Array.from({ length: 300 }, (_, index) => ({
      id: `long-${index}`,
      version: 1,
      at: index,
      kind: "assistant",
      text: `${"word ".repeat(200)}${index}`,
    }));
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height = this.classList.contains("acpmux-row") ? 40 : 0;
      return {
        x: 0,
        y: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: height,
        width: 0,
        height,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: conversation,
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      for (let frame = 0; frame < 3; frame += 1)
        await act(async () => {
          scroller.dispatchEvent(new dom.window.Event("scroll"));
        });
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });
});

describe("acpmux renderer registry", () => {
  test("registering the same renderer again does not re-render the pane", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    let firstRenders = 0;
    let secondRenders = 0;
    const FirstChips = () => {
      firstRenders += 1;
      return null;
    };
    const SecondChips = () => {
      secondRenders += 1;
      return null;
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", FirstChips as never));
      const afterRegister = firstRenders;
      expect(afterRegister).toBeGreaterThan(0);
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", FirstChips as never));
      expect(firstRenders).toBe(afterRegister);
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", SecondChips as never));
      expect(secondRenders).toBeGreaterThan(0);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });
});

describe("acpmux host handshake", () => {
  /// A loopback acpmux that answers the open handshake and can drop the socket.
  class FakeSocket {
    static OPEN = 1;
    static made: FakeSocket[] = [];
    readyState = 0;
    onopen?: () => void;
    onerror?: () => void;
    onclose?: () => void;
    onmessage?: (message: { data: string }) => void;
    constructor(readonly url: URL) {
      FakeSocket.made.push(this);
      queueMicrotask(() => {
        this.readyState = 1;
        this.onopen?.();
      });
    }
    send(raw: string) {
      const { id, method } = JSON.parse(raw) as { id: number; method: string };
      const result = method === "_acpmux/watch" ? { sessions: [] } : {};
      queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
    }
    close() {
      this.readyState = 3;
    }
    drop() {
      this.readyState = 3;
      this.onclose?.();
    }
  }

  /// The model picker reads the catalog through TanStack Query and keeps the old one across a reconnect.
  test("the model picker loads each daemon's catalog and keeps the last one while reconnecting", async () => {
    class CatalogSocket extends FakeSocket {
      static catalogs = [["m1"], ["m1", "m2"]];
      static holdHarnesses = false;
      static held: (() => void)[] = [];
      override send(raw: string) {
        const { id, method } = JSON.parse(raw) as { id: number; method: string };
        const models = CatalogSocket.catalogs[FakeSocket.made.indexOf(this)] ?? [];
        const result =
          method === "_acpmux/watch"
            ? { sessions: [{ sessionId: "s" }] }
            : method === "_acpmux/attach"
              ? { session: { sessionId: "s", harness: "codex", model: "m1" }, events: [] }
              : method === "_acpmux/harnesses"
                ? { harnesses: [{ id: "codex", name: "Codex", models: models.map((model) => ({ id: model })) }] }
                : {};
        const reply = () => this.onmessage?.({ data: JSON.stringify({ id, result }) });
        if (method === "_acpmux/harnesses" && CatalogSocket.holdHarnesses) CatalogSocket.held.push(reply);
        else queueMicrotask(reply);
      }
    }
    FakeSocket.made = [];
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    globals.WebSocket = CatalogSocket;
    host.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string }) {
            if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://127.0.0.1:4100/acp",
                token: "t",
                sessionId: "s",
              },
            });
          },
        },
      },
    };
    // The picker lists its models while open: open it once it exists, type "m" to list every
    // model (ids m1, m2), and read the matches.
    const models = () => {
      const doc = dom.window.document;
      const button = doc.querySelector<HTMLButtonElement>(".acpmux-model .acpmux-picker-button");
      if (button && button.getAttribute("aria-expanded") !== "true") button.click();
      if (button && doc.querySelector(".acpmux-mp .acpmux-menu-search")?.textContent !== "m")
        button.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "m", bubbles: true, cancelable: true }));
      return [...doc.querySelectorAll('.acpmux-mp [data-key^="model:"]')]
        .map((row) => row.getAttribute("data-key")!.slice("model:".length))
        .sort();
    };
    const waitFor = async (done: () => boolean) => {
      for (let tries = 0; tries < 100 && !done(); tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await waitFor(() => models().length > 0);
      expect(models()).toEqual(["m1"]);
      CatalogSocket.holdHarnesses = true;
      await act(async () => FakeSocket.made[0]!.drop());
      await waitFor(() => CatalogSocket.held.length > 0);
      expect(FakeSocket.made.length).toBe(2);
      expect(models()).toEqual(["m1"]);
      await act(async () => CatalogSocket.held.splice(0).forEach((reply) => reply()));
      await waitFor(() => models().length === 2);
      expect(models()).toEqual(["m1", "m2"]);
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
      FakeSocket.made = [];
    }
  });

  /// Onboarding's first task: the handshake's prompt starts the chat in its cwd without a Send press,
  /// and the composer stays empty. Swift hands the prompt out once, so it survives a first connect
  /// that fails (a daemon still starting) and is sent after the retry.
  test("a seeded prompt creates the chat in its cwd and sends once, even after a failed connect", async () => {
    const sent: { method: string; params: Record<string, unknown> }[] = [];
    let readies = 0;
    class PromptSocket extends FakeSocket {
      constructor(url: URL) {
        super(url);
        // The first daemon connect fails before it opens.
        if (FakeSocket.made.length === 1) {
          Object.defineProperty(this, "onopen", { get: () => undefined, set: () => undefined });
          queueMicrotask(() => this.onerror?.());
        }
      }
      override send(raw: string) {
        const { id, method, params } = JSON.parse(raw) as {
          id: number;
          method: string;
          params: Record<string, unknown>;
        };
        sent.push({ method, params });
        const result =
          method === "_acpmux/watch"
            ? { sessions: [] }
            : method === "session/new"
              ? { sessionId: "s-new" }
              : method === "_acpmux/attach"
                ? { session: { sessionId: "s-new", harness: "codex" }, events: [] }
                : {};
        queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
      }
    }
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    globals.WebSocket = PromptSocket;
    host.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string }) {
            if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
            readies += 1;
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://127.0.0.1:4100/acp",
                token: "t",
                newSession: true,
                cwd: "/tmp/first-task",
                ...(readies === 1 ? { prompt: "Leave a note on my Desktop" } : {}),
              },
            });
          },
        },
      },
    };
    const prompts = () => sent.filter((message) => message.method === "session/prompt");
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      for (let tries = 0; tries < 100 && prompts().length === 0; tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(readies).toBe(2);
      expect(sent.find((message) => message.method === "session/new")?.params.cwd).toBe("/tmp/first-task");
      expect(prompts().map((message) => message.params.sessionId)).toEqual(["s-new"]);
      expect(prompts()[0]!.params.prompt).toEqual([{ type: "text", text: "Leave a note on my Desktop" }]);
      expect(dom.window.document.querySelector("textarea")?.value ?? "").toBe("");
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
      FakeSocket.made = [];
    }
  });

  /// A resumed chat: the handshake's adopt is resumed on connect and becomes the tab's session at
  /// once, before any Send, so restoring the tab reopens that chat rather than an empty one.
  test("a resumed chat becomes the tab's session without a Send", async () => {
    const sent: { method: string; params: Record<string, unknown> }[] = [];
    const native: { method: string; params?: Record<string, unknown> }[] = [];
    class AdoptSocket extends FakeSocket {
      override send(raw: string) {
        const { id, method, params } = JSON.parse(raw) as {
          id: number;
          method: string;
          params: Record<string, unknown>;
        };
        sent.push({ method, params });
        const result =
          method === "_acpmux/watch"
            ? { sessions: [] }
            : method === "session/new"
              ? { sessionId: "s-adopted", _meta: { acpmux: { agentSessionId: "0a1b2c3d" } } }
              : method === "_acpmux/attach"
                ? { session: { sessionId: "s-adopted", harness: "claude" }, events: [] }
                : {};
        queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
      }
    }
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    globals.WebSocket = AdoptSocket;
    host.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string; params?: Record<string, unknown> }) {
            if (message.method !== "ready") {
              native.push(message);
              return Promise.resolve({ ok: true, value: null });
            }
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://127.0.0.1:4100/acp",
                token: "t",
                newSession: true,
                adopt: { harness: "claude", agentSessionId: "0a1b2c3d" },
              },
            });
          },
        },
      },
    };
    const persisted = () => native.filter((message) => message.method === "chat.persistSession");
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      for (let tries = 0; tries < 100 && persisted().length === 0; tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(persisted().map((message) => message.params?.sessionId)).toEqual(["s-adopted"]);
      expect(sent.filter((message) => message.method === "session/new")).toHaveLength(1);
      expect(sent.some((message) => message.method === "session/prompt")).toBe(false);
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
      FakeSocket.made = [];
    }
  });

  /// After losing the daemon the page asks Swift again; that retry restarted a daemon the user had stopped.
  test("a page that lost its daemon asks for a handshake that does not start one", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    const asked: Record<string, unknown>[] = [];
    globals.WebSocket = FakeSocket;
    host.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string; params: Record<string, unknown> }) {
            if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
            asked.push(message.params);
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://127.0.0.1:4100/acp",
                token: "t",
              },
            });
          },
        },
      },
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      for (let tries = 0; tries < 100 && FakeSocket.made.length === 0; tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(asked).toEqual([{}]);
      await act(async () => FakeSocket.made[0]!.drop());
      for (let tries = 0; tries < 100 && asked.length < 2; tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
      expect(asked[1]).toEqual({ reconnect: true });
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
    }
  });

  /// acpmux serves no git methods: the changes view's reads reach Swift with the session's folder.
  test("the changes view reads git from the native host in the selected session's folder", async () => {
    class FolderSocket extends FakeSocket {
      static git: string[] = [];
      override send(raw: string) {
        const { id, method } = JSON.parse(raw) as { id: number; method: string };
        if (method.startsWith("git.")) FolderSocket.git.push(method);
        const session = { sessionId: "s", cwd: "/work/app" };
        const result =
          method === "_acpmux/watch"
            ? { sessions: [session] }
            : method === "_acpmux/attach"
              ? { session, events: [] }
              : method.startsWith("git.")
                ? { files: [] }
                : {};
        queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
      }
    }
    FakeSocket.made = [];
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & Record<string, unknown>;
    const realSocket = globals.WebSocket;
    const asked: { method: string; params: Record<string, unknown> }[] = [];
    globals.WebSocket = FolderSocket;
    host.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string; params: Record<string, unknown> }) {
            if (message.method !== "ready") {
              asked.push({ method: message.method, params: message.params });
              return Promise.resolve({ ok: true, value: { scope: "staged", files: [] } });
            }
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://127.0.0.1:4100/acp",
                token: "t",
                sessionId: "s",
              },
            });
          },
        },
      },
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      for (let tries = 0; tries < 100 && !host.cmuxAcpmuxActions; tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      for (let tries = 0; tries < 10; tries += 1) await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
      expect(await host.cmuxAcpmuxActions!["git.diff"]!({ scope: "staged" })).toEqual({ scope: "staged", files: [] });
      await host.cmuxAcpmuxActions!["git.status"]!({});
      // The checkpoint control also asks for `git.capabilities`; this test is about the reads.
      expect(asked.filter((entry) => entry.method === "git.diff" || entry.method === "git.status")).toEqual([
        { method: "git.diff", params: { cwd: "/work/app", scope: "staged", include_patch: true } },
        { method: "git.status", params: { cwd: "/work/app" } },
      ]);
      expect(FolderSocket.git).toEqual([]);
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
      FakeSocket.made = [];
    }
  });
});

describe("acpmux turn diff", () => {
  test("View changes opens the turn's files; files collapse, and the toolbar toggles split view and the tree", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const document = dom.window.document;
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 2,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
          },
        },
        {
          kind: "tool",
          text: "Write notes.md",
          tool: {
            id: "t2",
            title: "Write notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "hello\n" }],
          },
        },
      ],
    };
    const turn: AcpmuxRow[] = [
      { id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" },
      diffRow,
      { id: "assistant-3", version: 1, at: 3, kind: "assistant", text: "done" },
    ];
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: turn,
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      const review = [...document.querySelectorAll("button")].find((button) => button.textContent === "View changes");
      expect(review).toBeDefined();
      (review as HTMLElement).focus();
      await act(async () => review!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      expect(panel.querySelector(".acpmux-diff-header strong")?.textContent).toBe("Last turn");
      expect(document.activeElement?.getAttribute("aria-label")).toBe("Back to transcript");
      // Each edit is one Pierre diff with the pane's own file header, in turn order.
      expect(
        [...panel.querySelectorAll(".acpmux-diff-file")].map((node) => (node as HTMLElement).dataset.path),
      ).toEqual(["/repo/src/main.ts", "/repo/notes.md"]);
      expect(
        [...panel.querySelectorAll(".acpmux-diff-file")].map((node) => node.querySelector("diffs-container") !== null),
      ).toEqual([true, true]);
      expect(
        panel.querySelector(".acpmux-diff-tree file-tree-container, .acpmux-diff-tree [class*=tree]"),
      ).not.toBeNull();
      const click = (node: Element) =>
        act(async () => {
          node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
        });
      const diffShown = () =>
        [...panel.querySelectorAll(".acpmux-diff-file")].map((node) => node.querySelector("diffs-container") !== null);
      // The file name folds its diff away and back; Mark as viewed folds it too.
      const name = () => panel.querySelector('.acpmux-diff-file[data-path="/repo/src/main.ts"] .acpmux-fh-name')!;
      await click(name());
      expect(diffShown()).toEqual([false, true]);
      expect(name().getAttribute("aria-expanded")).toBe("false");
      await click(name());
      expect(diffShown()).toEqual([true, true]);
      await click(panel.querySelector('[aria-label="Mark notes.md as viewed"]')!);
      expect(diffShown()).toEqual([true, false]);
      expect(panel.querySelector('[aria-label="Mark notes.md as not viewed"]')?.getAttribute("aria-pressed")).toBe(
        "true",
      );
      // Collapse all, then expand all.
      await click(panel.querySelector('[aria-label="Collapse all files"]')!);
      expect(diffShown()).toEqual([false, false]);
      await click(panel.querySelector('[aria-label="Expand all files"]')!);
      expect(diffShown()).toEqual([true, true]);
      const split = panel.querySelector('[aria-label="Split view"]')!;
      await click(split);
      expect(split.getAttribute("aria-pressed")).toBe("true");
      // Split view redraws the diffs and is remembered for the next time the view opens.
      expect(diffShown()).toEqual([true, true]);
      expect(dom.window.localStorage.getItem("cmux.acpmux.diffLayout")).toBe("split");
      // The tree filters by path, and the toolbar hides it.
      const filter = panel.querySelector<HTMLInputElement>('input[aria-label="Filter files"]')!;
      await act(async () => {
        filter.value = "zzz";
        filter.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
      });
      expect(panel.querySelector(".acpmux-diff-tree-empty")?.textContent).toBe("No matching files");
      await click(panel.querySelector('[aria-label="File tree"]')!);
      expect(panel.querySelector(".acpmux-diff-tree")).toBeNull();
      await click(panel.querySelector('[aria-label="File tree"]')!);
      expect(panel.querySelector(".acpmux-diff-tree")).not.toBeNull();
      const back = panel.querySelector('[aria-label="Back to transcript"]')!;
      await act(async () => back.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(document.querySelector(".acpmux-diff-panel")).toBeNull();
      // Focus goes back to the control that opened the view, once the transcript shows again.
      expect(document.activeElement).toBe(review!);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
      dom.window.localStorage.clear();
    }
  });

  test("a file's More menu copies its path and folds it, from the mouse or the keyboard", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const document = dom.window.document;
    const copied: string[] = [];
    const clipboard = Object.getOwnPropertyDescriptor(globalThis.navigator, "clipboard");
    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: { writeText: async (text: string) => void copied.push(text) },
    });
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 2,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
          },
        },
        {
          kind: "tool",
          text: "Write notes.md",
          tool: {
            id: "t2",
            title: "Write notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "hello\n" }],
          },
        },
      ],
    };
    const click = (node: Element) =>
      act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
    const key = (node: Element, name: string) =>
      act(async () => {
        node.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
      });
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const diffShown = () =>
        [...panel.querySelectorAll(".acpmux-diff-file")].map((node) => node.querySelector("diffs-container") !== null);
      const more = panel.querySelector<HTMLElement>('[aria-label="More actions for notes.md"]')!;
      expect(more).not.toBeNull();
      expect([more.getAttribute("aria-haspopup"), more.getAttribute("aria-expanded")]).toEqual(["menu", "false"]);
      const items = () => [...panel.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')];
      // The menu opens on its first item; Copy path copies the file's full path and closes it.
      more.focus();
      await click(more);
      expect(more.getAttribute("aria-expanded")).toBe("true");
      expect(items().map((item) => item.textContent)).toEqual(["Copy path", "Open file in a tab", "Collapse file"]);
      expect(document.activeElement).toBe(items()[0]);
      await click(items()[0]!);
      expect(copied).toEqual(["/repo/notes.md"]);
      expect(items()).toEqual([]);
      expect(document.activeElement).toBe(more);
      // From the keyboard: Arrow Down twice moves to Collapse file, Enter folds the file.
      await click(more);
      await key(items()[0]!, "ArrowDown");
      await key(document.activeElement!, "ArrowDown");
      expect(document.activeElement?.textContent).toBe("Collapse file");
      await key(document.activeElement!, "Enter");
      expect(diffShown()).toEqual([true, false]);
      expect(items()).toEqual([]);
      // Folded, the item opens the file again.
      await click(more);
      expect(items().map((item) => item.textContent)).toEqual(["Copy path", "Open file in a tab", "Expand file"]);
      await click(items()[2]!);
      expect(diffShown()).toEqual([true, true]);
      // Escape closes only the menu and returns focus to its button; the view stays open.
      await click(more);
      await key(items()[0]!, "Escape");
      expect(items()).toEqual([]);
      expect(document.activeElement).toBe(more);
      expect(document.querySelector(".acpmux-diff-panel")).not.toBeNull();
      // A press anywhere else closes it too.
      await click(more);
      await act(async () => {
        panel
          .querySelector(".acpmux-diff-header")!
          .dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
      });
      expect(items()).toEqual([]);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
      if (clipboard) Object.defineProperty(globalThis.navigator, "clipboard", clipboard);
      else delete (globalThis.navigator as unknown as Record<string, unknown>).clipboard;
    }
  });

  test("a changed file opens in a tab or the editor from its header and its More menu, and a failed open says so", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & {
      cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    };
    const document = dom.window.document;
    const asked: unknown[] = [];
    let refuse = false;
    host.cmuxAcpmuxActions = {
      "file.open": (params) => {
        asked.push(params);
        return refuse ? Promise.reject(new Error("The file could not be opened.")) : Promise.resolve(null);
      },
    };
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Write notes.md",
          tool: {
            id: "t2",
            title: "Write notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "hello\n" }],
          },
        },
      ],
    };
    const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
    const click = async (node: Element) => {
      await act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
      await settle();
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const tab = panel.querySelector<HTMLElement>('[aria-label="Open notes.md in a tab"]')!;
      const editor = panel.querySelector<HTMLElement>('[aria-label="Open notes.md in the editor"]')!;
      expect([tab?.title, editor?.title]).toEqual(["Open file in a tab", "Open in editor"]);
      // The header's buttons ask the host to open the file's full path.
      await click(tab);
      await click(editor);
      expect(asked).toEqual([
        { path: "/repo/notes.md", where: "tab" },
        { path: "/repo/notes.md", where: "editor" },
      ]);
      // So does the More menu's Open file in a tab.
      await click(panel.querySelector('[aria-label="More actions for notes.md"]')!);
      const item = [...panel.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
        (node) => node.textContent === "Open file in a tab",
      )!;
      await click(item);
      expect(asked.at(-1)).toEqual({ path: "/repo/notes.md", where: "tab" });
      expect(panel.querySelector('.acpmux-diff-notice[role="alert"]')).toBeNull();
      // A refused open says why, in the host's words; the next open clears it.
      refuse = true;
      await click(editor);
      expect(panel.querySelector('.acpmux-diff-notice[role="alert"]')?.textContent).toBe(
        "The file could not be opened.",
      );
      refuse = false;
      await click(tab);
      expect(panel.querySelector(".acpmux-diff-notice")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });

  test("an open's failure gives way to a later open or another scope, and a deleted file offers no open", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & {
      cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    };
    const document = dom.window.document;
    const opens: { resolve: (value: unknown) => void; reject: (error: Error) => void }[] = [];
    host.cmuxAcpmuxActions = {
      "file.open": () => new Promise((resolve, reject) => opens.push({ resolve, reject })),
      "git.diff": () =>
        Promise.resolve({
          scope: "uncommitted",
          root: "/repo",
          files: [
            { path: "src/main.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+A\n" },
            { path: "src/old.ts", status: "deleted", additions: 0, deletions: 1, patch: "@@ -1 +0,0 @@\n-gone\n" },
          ],
        }),
    };
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Write notes.md",
          tool: {
            id: "t2",
            title: "Write notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "hello\n" }],
          },
        },
      ],
    };
    const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
    const click = async (node: Element) => {
      await act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
      await settle();
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const notice = () => panel.querySelector('.acpmux-diff-notice[role="alert"]');
      const tab = panel.querySelector<HTMLElement>('[aria-label="Open notes.md in a tab"]')!;
      const editor = panel.querySelector<HTMLElement>('[aria-label="Open notes.md in the editor"]')!;
      // A slow open that fails after a later one worked says nothing: the file is open.
      await click(tab);
      await click(editor);
      opens[1].resolve(null);
      await settle();
      opens[0].reject(new Error("The file could not be opened."));
      await settle();
      expect(notice()).toBeNull();
      // A failure shows until another scope replaces the files it was about.
      await click(tab);
      opens[2].reject(new Error("The file could not be opened."));
      await settle();
      expect(notice()?.textContent).toBe("The file could not be opened.");
      await click(panel.querySelector('.acpmux-diff-header [aria-haspopup="menu"]')!);
      await click(
        [...panel.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
          (node) => node.textContent === "Uncommitted",
        )!,
      );
      expect(panel.querySelector('[aria-label="Open src/main.ts in a tab"]')).not.toBeNull();
      expect(notice()).toBeNull();
      // A deleted file has nothing on disk to open.
      expect(panel.querySelector('[aria-label="Open src/old.ts in a tab"]')).toBeNull();
      expect(panel.querySelector('[aria-label="Open src/old.ts in the editor"]')).toBeNull();
      await click(panel.querySelector('[aria-label="More actions for src/old.ts"]')!);
      const items = [...panel.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((node) => node.textContent);
      expect(items).toEqual(["Copy path", "Collapse file"]);
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });

  test("a file header keeps focus as its file folds, the tree opens a folded file, and Escape leaves the filter alone", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const document = dom.window.document;
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 2,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
          },
        },
        {
          kind: "tool",
          text: "Write notes.md",
          tool: {
            id: "t2",
            title: "Write notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "hello\n" }],
          },
        },
      ],
    };
    const click = (node: Element) =>
      act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const diffShown = () =>
        [...panel.querySelectorAll(".acpmux-diff-file")].map((node) => node.querySelector("diffs-container") !== null);
      // The pressed button stays focused, so the keyboard can press it again.
      const name = panel.querySelector<HTMLElement>(
        '.acpmux-diff-file[data-path="/repo/src/main.ts"] .acpmux-fh-name',
      )!;
      name.focus();
      await click(name);
      expect(diffShown()).toEqual([false, true]);
      expect(document.activeElement).toBe(name);
      await click(name);
      expect(document.activeElement).toBe(name);
      const eye = panel.querySelector<HTMLElement>('[aria-label="Mark notes.md as viewed"]')!;
      eye.focus();
      await click(eye);
      expect(diffShown()).toEqual([true, false]);
      expect(document.activeElement).toBe(eye);
      // Picking the file the tree already has selected still opens it after Collapse all.
      await click(panel.querySelector('[aria-label="Collapse all files"]')!);
      const row = panel
        .querySelector("file-tree-container")!
        .shadowRoot!.querySelector('[data-item-path="src/main.ts"]')!;
      expect(row.getAttribute("aria-selected")).toBe("true");
      // A real click is composed, so it leaves the tree's shadow root.
      await act(async () => {
        row.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, composed: true }));
      });
      expect(diffShown()).toEqual([true, false]);
      // Enter on the selected row does the same from the keyboard; Cmd-click deselects only.
      const rowKey = () =>
        act(async () => {
          row.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, composed: true }));
        });
      await click(panel.querySelector('[aria-label="Collapse all files"]')!);
      await rowKey();
      expect(diffShown()).toEqual([true, false]);
      await click(panel.querySelector('[aria-label="Collapse all files"]')!);
      await act(async () => {
        row.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, composed: true, metaKey: true }));
      });
      expect(diffShown()).toEqual([false, false]);
      // Escape clears the filter field rather than closing the view.
      const filter = panel.querySelector<HTMLInputElement>('input[aria-label="Filter files"]')!;
      filter.focus();
      await act(async () => {
        dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" }));
      });
      expect(document.querySelector(".acpmux-diff-panel")).not.toBeNull();
      name.focus();
      await act(async () => {
        dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" }));
      });
      expect(document.querySelector(".acpmux-diff-panel")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });

  test("edits without a diff list once each in the card, and the card's estimate counts them", async () => {
    const plain = (id: string, summary: string) => ({
      kind: "tool" as const,
      text: "Edit",
      tool: { id, title: "Edit", kind: "edit" as const, status: "completed" as const, inputSummary: summary },
    });
    const root = await renderCard(
      {
        id: "activity-1",
        version: 1,
        at: 1,
        kind: "activity",
        items: [plain("t1", "notes.txt"), plain("t2", "notes.txt")],
      },
      [],
    );
    const document = dom.window.document;
    try {
      expect(document.querySelector(".acpmux-edited-title")?.textContent).toBe("Edited 1 file");
      expect([...document.querySelectorAll(".acpmux-edited-file")].map((file) => file.textContent)).toEqual([
        "notes.txt",
      ]);
    } finally {
      await act(async () => root.unmount());
    }
    // A lone diffless edit lists as a row under the head; a lone diff is named in the head.
    expect(editedCardHeight(0, 1)).toBe(editedCardHeight(2) - 34);
    expect(editedCardHeight(1)).toBe(58);
  });

  const editRow = (paths: string[]): AcpmuxRow => ({
    id: "activity-1",
    version: 1,
    at: 1,
    kind: "activity",
    items: paths.map((path, index) => ({
      kind: "tool",
      text: "Edit",
      tool: {
        id: `t${index}`,
        title: "Edit",
        kind: "edit",
        status: "completed",
        diffs: [{ path, oldText: "1\n", newText: "2\n3\n" }],
      },
    })),
  });
  const renderCard = async (row: AcpmuxRow, opened: [string, string | undefined][]) => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () =>
      root.render(
        createElement(VirtualTranscript, {
          rows: [row],
          onToggleActivity: () => {},
          onOpenDiff: (rowId: string, path?: string) => opened.push([rowId, path]),
          expanded: new Set<string>(),
        }),
      ),
    );
    return root;
  };

  test("the edited-files card totals the turn's files, and each file opens the changes at that file", async () => {
    const opened: [string, string | undefined][] = [];
    const root = await renderCard(editRow(["/repo/src/a.ts", "/repo/b.ts"]), opened);
    const document = dom.window.document;
    try {
      expect(document.querySelector(".acpmux-edited-title")?.textContent).toBe("Edited 2 files+4-2");
      const files = [...document.querySelectorAll(".acpmux-edited-file")];
      expect(files.map((file) => file.textContent)).toEqual(["src/a.ts+2-1", "b.ts+2-1"]);
      await act(async () => files[0]!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(opened).toEqual([["activity-1", "/repo/src/a.ts"]]);
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("one edited file is named in the card, and many show the first three", async () => {
    const opened: [string, string | undefined][] = [];
    const document = dom.window.document;
    let root = await renderCard(editRow(["/repo/a.ts"]), opened);
    try {
      expect(document.querySelector(".acpmux-edited-title > div")?.textContent).toBe("Edited a.ts");
      expect(document.querySelectorAll(".acpmux-edited-file")).toHaveLength(0);
      const view = [...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!;
      await act(async () => view.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(opened).toEqual([["activity-1", "/repo/a.ts"]]);
    } finally {
      await act(async () => root.unmount());
    }
    root = await renderCard(editRow(["/r/a.ts", "/r/b.ts", "/r/c.ts", "/r/d.ts", "/r/e.ts"]), opened);
    try {
      expect(document.querySelectorAll(".acpmux-edited-file")).toHaveLength(3);
      const more = document.querySelector(".acpmux-edited-more")!;
      expect(more.textContent).toBe("Show 2 more files");
      await act(async () => more.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(document.querySelectorAll(".acpmux-edited-file")).toHaveLength(5);
      expect(document.querySelector(".acpmux-edited-more")?.textContent).toBe("Show fewer files");
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("the scope menu loads a git scope, fails with Retry, shows an empty scope, and returns to the turn", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & {
      cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    };
    const document = dom.window.document;
    const asked: unknown[] = [];
    const answers: (() => Promise<unknown>)[] = [
      () => Promise.reject(new Error("Not a git repository")),
      () =>
        Promise.resolve({
          scope: "uncommitted",
          root: "/repo",
          files: [
            {
              path: "src/main.ts",
              status: "modified",
              additions: 1,
              deletions: 1,
              patch: "@@ -1,2 +1,2 @@\n-a\n+A\n b\n",
            },
          ],
        }),
      // Picked again, Uncommitted loads afresh; this answer never comes.
      () => new Promise(() => {}),
      () => Promise.resolve({ scope: "staged", files: [] }),
    ];
    host.cmuxAcpmuxActions = {
      "git.diff": (params) => {
        asked.push(params);
        return answers.shift()!();
      },
    };
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
          },
        },
      ],
    };
    const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
    const click = async (node: Element) => {
      await act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
      await settle();
    };
    const key = (node: Element, name: string) =>
      act(async () => {
        node.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
      });
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const paths = () =>
        [...panel.querySelectorAll<HTMLElement>(".acpmux-diff-file")].map((node) => node.dataset.path);
      const pill = panel.querySelector<HTMLElement>('.acpmux-diff-header [aria-haspopup="menu"]')!;
      expect(pill).not.toBeNull();
      expect(pill.querySelector("strong")?.textContent).toBe("Last turn");
      const items = () => [...panel.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitemradio"]')];
      const eye = () => panel.querySelector<HTMLElement>(".acpmux-diff-file [aria-pressed]")!;
      // The turn's file, marked viewed, folds away.
      await click(eye());
      expect(eye().getAttribute("aria-pressed")).toBe("true");
      expect(panel.querySelector(".acpmux-diff-file diffs-container")).toBeNull();
      // The menu lists the scopes in a fixed order, in three groups, and opens on the chosen one.
      pill.focus();
      await click(pill);
      expect(pill.getAttribute("aria-expanded")).toBe("true");
      expect(items().map((item) => item.textContent)).toEqual([
        "Last turn",
        "Uncommitted",
        "Unstaged",
        "Staged",
        "Committed",
        "Branch",
      ]);
      expect(panel.querySelectorAll('[role="menu"] hr').length).toBe(2);
      expect(items().map((item) => item.getAttribute("aria-checked"))).toEqual([
        "true",
        "false",
        "false",
        "false",
        "false",
        "false",
      ]);
      expect(document.activeElement).toBe(items()[0]);
      // A scope that fails to load says so and offers Retry; Retry asks again and shows its files.
      await click(items()[1]!);
      expect(asked).toEqual([{ scope: "uncommitted", include_patch: true }]);
      expect(items()).toEqual([]);
      expect(document.activeElement).toBe(pill);
      expect(pill.querySelector("strong")?.textContent).toBe("Uncommitted");
      const failure = panel.querySelector('[role="alert"]');
      expect(failure?.querySelector("strong")?.textContent).toBe("Couldn't load changes");
      expect(paths()).toEqual([]);
      // With no files the pill names the scope only.
      expect(pill.querySelector(".acpmux-diff-counts")).toBeNull();
      const retryButton = [...failure!.querySelectorAll<HTMLElement>("button")].find(
        (button) => button.textContent === "Retry",
      )!;
      retryButton.focus();
      expect(document.activeElement).toBe(retryButton);
      await click(retryButton);
      expect(asked).toEqual([
        { scope: "uncommitted", include_patch: true },
        { scope: "uncommitted", include_patch: true },
      ]);
      // Retry leaves as the load starts; focus moves to the scope pill, not the page.
      expect(document.activeElement).toBe(pill);
      expect(panel.querySelector('[role="alert"]')).toBeNull();
      expect(paths()).toEqual(["/repo/src/main.ts"]);
      expect(panel.querySelector(".acpmux-diff-file .acpmux-fh-name")?.textContent).toBe("src/main.ts");
      // The same file in another scope is other contents: open and not viewed.
      expect(eye().getAttribute("aria-pressed")).toBe("false");
      expect(panel.querySelector(".acpmux-diff-file diffs-container")).not.toBeNull();
      expect(pill.querySelector(".acpmux-diff-add")?.textContent).toBe("+1");
      // Back to Last turn and to Uncommitted again: it loads afresh, without its old files.
      await click(pill);
      await click(items()[0]!);
      expect(paths()).toEqual(["/repo/src/main.ts"]);
      await click(pill);
      await click(items()[1]!);
      expect(asked.length).toBe(3);
      expect(paths()).toEqual([]);
      expect(panel.querySelector("output")?.textContent).toBe("Loading changes…");
      // A scope with nothing in it says so. An arrow key opens the menu from the pill too.
      await key(pill, "ArrowDown");
      expect(document.activeElement?.textContent).toBe("Uncommitted");
      await key(document.activeElement!, "ArrowDown");
      await key(document.activeElement!, "ArrowDown");
      expect(document.activeElement?.textContent).toBe("Staged");
      await key(document.activeElement!, "Enter");
      await settle();
      expect(asked.at(-1)).toEqual({ scope: "staged", include_patch: true });
      expect(asked.length).toBe(4);
      expect(panel.querySelector("output strong")?.textContent).toBe("No changes");
      // Last turn is the transcript's own files again, without asking the host.
      await click(pill);
      await key(document.activeElement!, "Home");
      await key(document.activeElement!, "Enter");
      await settle();
      expect(asked.length).toBe(4);
      expect(paths()).toEqual(["/repo/src/main.ts"]);
      expect(pill.querySelector("strong")?.textContent).toBe("Last turn");
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });

  test("the options menu refreshes a scope, toggles the view in words, and copies a git apply command", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & {
      cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    };
    const document = dom.window.document;
    const copied: string[] = [];
    const clipboard = Object.getOwnPropertyDescriptor(globalThis.navigator, "clipboard");
    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: { writeText: async (text: string) => void copied.push(text) },
    });
    const asked: unknown[] = [];
    host.cmuxAcpmuxActions = {
      "git.diff": async (params) => {
        asked.push(params);
        return {
          scope: "uncommitted",
          root: "/repo",
          files: [
            {
              path: "src/main.ts",
              status: "modified",
              additions: 1,
              deletions: 1,
              patch: "@@ -1,2 +1,2 @@\n-a\n+A\n b\n",
            },
          ],
          total_files: 1,
          files_omitted: 0,
        };
      },
    };
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
          },
        },
      ],
    };
    const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
    const click = async (node: Element) => {
      await act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
      await settle();
    };
    const key = (node: Element, name: string) =>
      act(async () => {
        node.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
      });
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const options = panel.querySelector<HTMLElement>('[data-tool="options"]')!;
      expect(options?.getAttribute("aria-label")).toBe("Changes options");
      // Escape is the page's own key, not an app shortcut, so the tooltip shows no keycap.
      expect(panel.querySelector(".acpmux-diff-back")?.getAttribute("title")).toBe("Back to transcript");
      const rows = () => [
        ...panel.querySelectorAll<HTMLButtonElement>('[aria-label="Changes options"][role="menu"] [role="menuitem"]'),
      ];
      const row = (label: string) => rows().find((item) => item.textContent === label)!;
      const tool = (id: string) => panel.querySelector<HTMLElement>(`[data-tool="${id}"]`)!;
      // Last turn comes from the transcript: nothing to refresh and no git patches to copy.
      await click(options);
      expect(options.getAttribute("aria-expanded")).toBe("true");
      expect(rows().map((item) => [item.textContent, item.getAttribute("aria-disabled") === "true"])).toEqual([
        ["Refresh", true],
        ["Word wrap", false],
        ["Switch to split diff", false],
        ["Collapse all diffs", false],
        ["Copy git apply command", true],
      ]);
      expect(document.activeElement).toBe(row("Word wrap"));
      // A disabled row is still in the menu for the keyboard and a screen reader, and does nothing.
      await key(document.activeElement!, "ArrowUp");
      expect(document.activeElement).toBe(row("Refresh"));
      await key(document.activeElement!, "Enter");
      await settle();
      expect([rows().length, asked.length]).toEqual([5, 0]);
      await key(document.activeElement!, "ArrowDown");
      // A row runs the same toggle as its toolbar button, and the menu then names the way back.
      await click(row("Word wrap"));
      expect(rows()).toEqual([]);
      expect(tool("wrap").getAttribute("aria-pressed")).toBe("true");
      await click(options);
      expect(row("Disable word wrap")).toBeDefined();
      await click(row("Collapse all diffs"));
      expect(tool("collapse").getAttribute("aria-pressed")).toBe("true");
      await click(options);
      expect(row("Expand all diffs")).toBeDefined();
      // Escape closes the menu, not the changes view, and focus returns to the button.
      await key(document.activeElement!, "Escape");
      expect(rows()).toEqual([]);
      expect(document.activeElement).toBe(options);
      expect(document.querySelector("section.acpmux-diff-panel")).not.toBeNull();
      // A git scope refreshes from the host and copies its patches as one git apply command.
      const pill = panel.querySelector<HTMLElement>(".acpmux-diff-scope")!;
      await click(pill);
      await click(
        [...panel.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
          (item) => item.textContent === "Uncommitted",
        )!,
      );
      expect(asked.length).toBe(1);
      await click(options);
      await click(row("Refresh"));
      expect(asked.length).toBe(2);
      await click(options);
      await click(row("Copy git apply command"));
      expect(copied).toEqual([
        `git -C "$(git rev-parse --show-toplevel)" apply <<'CMUX_PATCH'\ndiff --git a/src/main.ts b/src/main.ts\n--- a/src/main.ts\n+++ b/src/main.ts\n@@ -1,2 +1,2 @@\n-a\n+A\n b\nCMUX_PATCH\n`,
      ]);
      expect(document.activeElement).toBe(options);
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
      for (const name of ["cmux.acpmux.diffWrap", "cmux.acpmux.diffLayout", "cmux.acpmux.diffTree"])
        dom.window.localStorage.removeItem(name);
      if (clipboard) Object.defineProperty(globalThis.navigator, "clipboard", clipboard);
      else delete (globalThis.navigator as unknown as Record<string, unknown>).clipboard;
    }
  });

  test("a scope that skipped untracked files says so, and the branch scope names its branch and base", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window & {
      cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    };
    const document = dom.window.document;
    const copied: string[] = [];
    const clipboard = Object.getOwnPropertyDescriptor(globalThis.navigator, "clipboard");
    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: { writeText: async (text: string) => void copied.push(text) },
    });
    const diffs: unknown[] = [];
    let statuses = 0;
    let skipped = 1234;
    const file = {
      path: "src/main.ts",
      status: "modified",
      additions: 1,
      deletions: 1,
      patch: "@@ -1 +1 @@\n-a\n+A\n",
    };
    host.cmuxAcpmuxActions = {
      "git.diff": async (params) => {
        diffs.push(params.scope);
        return params.scope === "branch"
          ? { scope: "branch", root: "/repo", base: "4be1c2e", files: [file], total_files: 1, files_omitted: 0 }
          : {
              scope: params.scope,
              root: "/repo",
              files: [file],
              total_files: 1,
              files_omitted: 0,
              untracked_skipped: skipped,
            };
      },
      "git.status": async () => {
        statuses += 1;
        return {
          root: "/repo",
          branch: "feat-retry",
          upstream: "origin/feat-retry",
          base: "origin/main",
          ahead: 2,
          behind: 0,
        };
      },
    };
    const diffRow: AcpmuxRow = {
      id: "activity-2",
      version: 1,
      at: 2,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Edit main.ts",
          tool: {
            id: "t1",
            title: "Edit main.ts",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/src/main.ts", oldText: "a\n", newText: "A\n" }],
          },
        },
      ],
    };
    const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
    const click = async (node: Element) => {
      await act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
      await settle();
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          type: "snapshot",
          protocolVersion: 1,
          rows: [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow],
          sessions: [],
          connection: "connected",
          isWorking: false,
          queue: [],
          catalog: [],
          canLoadOlder: false,
        }),
      );
      await click([...document.querySelectorAll("button")].find((button) => button.textContent === "View changes")!);
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      const banner = () => panel.querySelector<HTMLElement>(".acpmux-changes-banner");
      const branch = () => panel.querySelector<HTMLElement>(".acpmux-branch-pill");
      const pick = async (label: string) => {
        await click(panel.querySelector<HTMLElement>(".acpmux-diff-scope")!);
        await click(
          [...panel.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
            (item) => item.textContent === label,
          )!,
        );
      };
      // Last turn comes from the transcript: no skipped files and no branch.
      expect([banner(), branch(), statuses]).toEqual([null, null, 0]);
      await pick("Uncommitted");
      // Only the message is announced, not the buttons beside it.
      expect(banner()?.getAttribute("role")).toBeNull();
      expect(banner()?.querySelector('[role="status"]')?.className).toBe("acpmux-changes-banner-text");
      expect(banner()?.querySelector(".acpmux-changes-banner-title")?.textContent).toBe("Showing tracked changes only");
      expect(banner()?.querySelector(".acpmux-changes-banner-body")?.textContent).toBe(
        "The Changes tab skipped 1,234 untracked files to stay responsive. If these files are generated, clean them up and refresh",
      );
      expect([branch(), statuses]).toEqual([null, 0]);
      const action = (label: string) =>
        [...banner()!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === label)!;
      // The cleanup command is a dry run that lists the untracked files the scope left out.
      await click(action("Copy cleanup command"));
      expect(copied).toEqual(["git clean -nd"]);
      // Refresh replaces the banner, so focus moves to the scope pill; the new count shows.
      skipped = 1;
      await click(action("Refresh"));
      expect(diffs).toEqual(["uncommitted", "uncommitted"]);
      expect(document.activeElement).toBe(panel.querySelector(".acpmux-diff-scope"));
      expect(banner()?.querySelector(".acpmux-changes-banner-body")?.textContent).toBe(
        "The Changes tab skipped 1 untracked file to stay responsive. If these files are generated, clean them up and refresh",
      );
      // The branch scope names the branch and the base it is compared with.
      await pick("Branch");
      expect(banner()).toBeNull();
      expect(branch()?.querySelector(".acpmux-branch-from")?.textContent).toBe("feat-retry");
      expect(branch()?.querySelector(".acpmux-branch-to")?.textContent).toBe("origin/main");
      expect(branch()?.textContent).toBe("feat-retry compared with origin/main");
      expect(statuses).toBe(1);
      // A refresh asks for the branch again too.
      await click(panel.querySelector<HTMLElement>('[data-tool="options"]')!);
      await click(
        [...panel.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === "Refresh")!,
      );
      expect([diffs.length, statuses]).toEqual([4, 2]);
      // A status asked before a refresh never names the branch after it.
      const pending: ((branch: string) => void)[] = [];
      host.cmuxAcpmuxActions["git.status"] = () =>
        new Promise((resolve) => pending.push((name) => resolve({ branch: name, base: "origin/main" })));
      await click(panel.querySelector<HTMLElement>('[data-tool="options"]')!);
      await click(
        [...panel.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === "Refresh")!,
      );
      expect([branch(), pending.length]).toEqual([null, 1]);
      await click(panel.querySelector<HTMLElement>('[data-tool="options"]')!);
      await click(
        [...panel.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === "Refresh")!,
      );
      await act(async () => pending[1]!("feat-new"));
      await act(async () => pending[0]!("feat-old"));
      await settle();
      expect(branch()?.querySelector(".acpmux-branch-from")?.textContent).toBe("feat-new");
      // A failed status leaves the scope's diffs and names no branch.
      host.cmuxAcpmuxActions["git.status"] = async () => {
        throw new Error("Not a git repository");
      };
      await pick("Uncommitted");
      await pick("Branch");
      expect([branch(), panel.querySelectorAll(".acpmux-diff-file").length > 0]).toEqual([null, true]);
      // A detached head has no branch to name, even when the host still sends its last one.
      host.cmuxAcpmuxActions["git.status"] = async () => ({
        root: "/repo",
        detached: true,
        branch: "feat-retry",
        base: "origin/main",
        ahead: 0,
        behind: 0,
      });
      await pick("Uncommitted");
      await pick("Branch");
      expect(branch()).toBeNull();
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
      if (clipboard) Object.defineProperty(globalThis.navigator, "clipboard", clipboard);
      else delete (globalThis.navigator as unknown as Record<string, unknown>).clipboard;
    }
  });
});

describe("acpmux composer", () => {
  /// Codex has no modes: its mode picker drew as an empty pill next to the model picker, and Stop sat beside Send between turns.
  test("shows only the pickers that have choices, and Stop only while a turn runs", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const snapshot = (isWorking: boolean) => ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "connected",
      isWorking,
      queue: [],
      canLoadOlder: false,
      catalog: [{ id: "codex", models: [{ id: "gpt", name: "GPT" }] }],
      summary: { harness: "codex", model: "gpt", modes: { availableModes: [], currentModeId: null } },
    });
    const composer = () => dom.window.document.querySelector(".acpmux-composer")!;
    const buttons = () =>
      Array.from(composer().querySelectorAll(".acpmux-send"), (button) => button.getAttribute("aria-label"));
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot(false) as never));
      expect(composer().querySelector("[aria-label=Model]")).not.toBeNull();
      expect(composer().querySelector("[aria-label=Mode]")).toBeNull();
      expect(buttons()).toEqual(["Send"]);
      await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot(true) as never));
      // Send turns into Stop while a turn runs and the prompt is empty.
      expect(buttons()).toEqual(["Stop"]);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });
});

describe("acpmux turn counts", () => {
  /// The fold and the turn summary read "1 tool calls". A finished turn folds its work under
  /// one "Worked for" line that carries the count.
  test("one tool call is counted in the singular", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const turn: AcpmuxRow[] = [
      { id: "u", version: 1, at: 1, kind: "user", text: "run it" },
      { id: "a", version: 1, at: 2, kind: "activity", toolCount: 1, items: [{ kind: "tool", text: "Run total.py" }] },
      { id: "s", version: 1, at: 3, kind: "turnSummary", durationMs: 3000, toolCount: 1 },
    ];
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: turnView(turn, new Set()),
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      expect(dom.window.document.querySelector(".cv-worked")?.textContent).toBe("Worked for 3s");
      expect(dom.window.document.querySelector(".cv-turn-summary")).toBeNull();
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// History loaded from mid-turn has no user message to time the turn from.
  test("a summary without a start time shows only the count", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [{ id: "s", version: 1, at: 3, kind: "turnSummary", toolCount: 2 }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      expect(dom.window.document.querySelector(".cv-turn-summary")?.textContent).toBe("2 tool calls");
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux docked permission asks", () => {
  test("folder trust coexists with a group without duplicating its individual controls", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const priorActions = host.cmuxAcpmuxActions;
    host.cmuxAcpmuxActions = { "acp.trust.get": async ({ cwd }) => ({ cwd, level: "unknown" }) };
    const permission = {
      permissionId: "p",
      groupId: "g",
      pending: true,
      title: "Write app.ts",
      options: [{ id: "yes", name: "Individual allow", allow: true }],
    };
    const snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      sessionId: "s",
      summary: { sessionId: "s", cwd: "/repo/app", harness: "claude", turnCount: 1 },
      rows: [
        { id: "u", version: 1, at: 1, kind: "user", text: "fix it" },
        { id: "p", version: 1, at: 2, kind: "permission", permission },
      ],
      sessions: [],
      connection: "connected",
      isWorking: true,
      queue: [],
      catalog: [],
      canLoadOlder: false,
      permission,
      permissionGroups: {
        supported: true,
        ready: true,
        chatAllowance: false,
        busy: false,
        loading: false,
        groups: [
          {
            groupId: "g",
            sessionId: "s",
            turnId: "t",
            revision: 1,
            state: "pending",
            decision: null,
            decisions: ["allow_once", "allow_chat", "deny"],
            items: [
              { permissionId: "p", state: "pending", request: { toolCall: { title: "Write app.ts", kind: "edit" } } },
            ],
          },
        ],
      },
    };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot as never));
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      expect(dom.window.document.querySelector(".acpmux-trust-ask")).not.toBeNull();
      const buttons = () => [...dom.window.document.querySelectorAll("button")].map((button) => button.textContent);
      expect(buttons()).toContain("Allow for this chat");
      expect(buttons().some((label) => label?.endsWith("Individual allow"))).toBe(false);
      // An interactive request remains individually answerable beside both asks.
      await act(async () =>
        host.cmuxAcpmuxBridge!.receive({
          ...snapshot,
          permission: { ...permission, permissionId: "interactive", groupId: undefined },
        } as never),
      );
      expect(buttons().some((label) => label?.endsWith("Individual allow"))).toBe(true);
      expect(buttons()).toContain("Allow for this chat");
      expect(dom.window.document.querySelector(".acpmux-trust-ask")).not.toBeNull();
    } finally {
      await act(async () => root.unmount());
      host.cmuxAcpmuxActions = priorActions;
    }
  });
});

describe("acpmux new chat", () => {
  /// A new chat drew an empty transcript; it now names the project.
  test("an attached session with no turns shows the hero with its folder; rows, turns, a queued prompt, a lost daemon or a missing summary hide it", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const snapshot = ({
      rows = [] as unknown[],
      connection = "connected",
      cwd = "/Users/me/harness-research/" as string | undefined,
      turnCount = 0 as number | null,
      summary = true,
      queue = [] as { id: string; prompt: string }[],
      canLoadOlder = true,
    } = {}) => ({
      type: "snapshot",
      protocolVersion: 1,
      rows,
      sessions: [],
      connection,
      sessionId: "s",
      isWorking: false,
      queue,
      canLoadOlder,
      catalog: [],
      summary: summary ? { sessionId: "s", cwd, turnCount: turnCount ?? undefined } : undefined,
    });
    const hero = () => dom.window.document.querySelector(".acpmux-empty-title")?.textContent;
    const show = async (value: ReturnType<typeof snapshot>) =>
      act(async () => host.cmuxAcpmuxBridge!.receive(value as never));
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await show(snapshot({ connection: "connecting: connection refused" }));
      expect(hero()).toBeUndefined();
      await show(snapshot());
      expect(hero()).toBe("What should we build in harness-research?");
      expect(dom.window.document.querySelector(".acpmux-scroll")).toBeNull();
      await show(snapshot({ cwd: "/Users/me" }));
      expect(hero()).toBe("What should we build?");
      // Between a session's reset and its attach there is no summary yet.
      await show(snapshot({ summary: false }));
      expect(hero()).toBeUndefined();
      await show(snapshot({ turnCount: 2 }));
      expect(hero()).toBeUndefined();
      // A prompt waiting to start is not an empty chat.
      await show(snapshot({ queue: [{ id: "p1", prompt: "first" }] }));
      expect(hero()).toBeUndefined();
      // A daemon that doesn't count turns (null here): older history means an old session.
      await show(snapshot({ turnCount: null }));
      expect(hero()).toBeUndefined();
      await show(snapshot({ turnCount: null, canLoadOlder: false }));
      expect(hero()).toBe("What should we build in harness-research?");
      await show(snapshot({ rows: [{ id: "u1", version: 1, at: 1, kind: "user", text: "hi" }] }));
      expect(hero()).toBeUndefined();
      expect(dom.window.document.querySelector(".acpmux-scroll")).not.toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("the folder is the sidebar's project label, without the home folder or the root", async () => {
    const { projectName } = await import("./EmptyState");
    expect(projectName("/Users/me/cmux")).toBe("cmux");
    expect(projectName("/Users/me/cmux//")).toBe("cmux");
    expect(projectName("/Users/me")).toBeUndefined();
    expect(projectName("/")).toBeUndefined();
    expect(projectName(undefined)).toBeUndefined();
  });
});

describe("acpmux live turn status", () => {
  /// A running turn showed nothing until its first output, and no time while it worked.
  test("a running turn says Thinking, then Working over its work, then folds when it ends", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const user: AcpmuxRow = { id: "u", version: 1, at: Date.now() - 42_000, kind: "user", text: "run it" };
    const work: AcpmuxRow = {
      id: "a",
      version: 1,
      at: user.at + 2_000,
      kind: "activity",
      toolCount: 1,
      items: [{ kind: "tool", text: "Run total.py" }],
    };
    const draw = (rows: AcpmuxRow[], working: boolean) =>
      act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: turnView(rows, new Set(), { working }),
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
    const status = () => dom.window.document.querySelector(".cv-worked");
    try {
      await draw([user, { id: "typing", version: 1, at: user.at, kind: "typing" }], true);
      expect(status()?.textContent).toBe("Thinking");
      expect(dom.window.document.querySelector(".cv-thinking")).not.toBeNull();

      await draw([user, work], true);
      expect(status()?.textContent).toMatch(/^Working for 4[23]s$/);
      // A status, not a control: nothing to open until the turn ends.
      expect(status()?.tagName).toBe("DIV");
      expect(dom.window.document.querySelector(".cv-thinking")).toBeNull();

      await draw([user, work, { id: "s", version: 1, at: user.at + 50_000, kind: "turnSummary", toolCount: 1 }], false);
      expect(status()?.tagName).toBe("BUTTON");
      expect(status()?.textContent).toBe("Worked for 50s");
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  test("the Working line ticks each second", async () => {
    const { WorkingFor } = await import("./conversation/WorkingFor");
    const root = createRoot(dom.window.document.getElementById("root")!);
    let clock = 42_000;
    const now = () => clock;
    try {
      await act(async () =>
        root.render(createElement(WorkingFor, { row: { id: "working-u", version: 1, at: 0, kind: "working" }, now })),
      );
      const label = () => dom.window.document.querySelector(".cv-worked__label")?.textContent;
      expect(label()).toBe("Working for 42s");
      clock = 61_000;
      await act(() => new Promise((resolve) => setTimeout(resolve, 1_100)));
      expect(label()).toBe("Working for 1m 1s");
      // While text streams, the line holds at the text's start instead of ticking.
      const held = { id: "working-u", version: 2, at: 0, kind: "working", durationMs: 15_000 };
      await act(async () => root.render(createElement(WorkingFor, { row: held, now })));
      expect(label()).toBe("Working for 15s");
      clock = 90_000;
      await act(() => new Promise((resolve) => setTimeout(resolve, 1_100)));
      expect(label()).toBe("Working for 15s");
    } finally {
      await act(async () => root.unmount());
    }
  });
});

describe("acpmux tool runs", () => {
  const call = (id: string, kind: string, status = "completed") => ({
    kind: "tool",
    text: id,
    tool: { id, title: id, kind, status },
  });

  /// In an ended turn's open "Worked for", a run of calls folds under one summary line.
  test("a run in an ended turn shows one summary line and opens to its calls", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const items = [call("Read upload.ts", "read"), call("Search for retry", "search"), call("Run bun test", "execute")];
    const texts = () => [...dom.window.document.querySelectorAll(".cv-tool")].map((node) => node.textContent);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [{ id: "a", version: 1, at: 1, kind: "activity", settled: true, items }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const summary = dom.window.document.querySelector<HTMLButtonElement>(".cv-tool.is-toggle")!;
      expect(texts()).toEqual(["Read files, ran a command"]);
      expect(summary.getAttribute("aria-expanded")).toBe("false");
      await act(async () => summary.click());
      expect(summary.getAttribute("aria-expanded")).toBe("true");
      expect(texts()).toEqual(["Read files, ran a command", "Read upload.ts", "Search for retry", "Run bun test"]);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A live turn never folds, so its rows keep their height as each call starts and ends.
  test("a live turn lists each call until it ends, then folds inside the open fold", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const user: AcpmuxRow = { id: "u", version: 1, at: 1, kind: "user", text: "fix it" };
    const activity = (version: number, last: string): AcpmuxRow => ({
      id: "a",
      version,
      at: 2,
      kind: "activity",
      items: [call("Read upload.ts", "read"), call("Run bun test", "execute", last)],
    });
    const texts = () => [...dom.window.document.querySelectorAll(".cv-tool")].map((node) => node.textContent);
    const show = (rows: AcpmuxRow[], open: Set<string>) =>
      act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: turnView(rows, open),
            onToggleActivity: () => {},
            expanded: open,
          }),
        ),
      );
    try {
      for (const [version, status] of [
        [1, "completed"],
        [2, "pending"],
        [3, "completed"],
      ] as const) {
        await show([user, activity(version, status)], new Set());
        expect(texts()).toEqual(["Read upload.ts", "Run bun test"]);
      }
      const ended = [user, activity(3, "completed"), { id: "s", version: 1, at: 9, kind: "turnSummary", toolCount: 2 }];
      await show(ended, new Set());
      expect(texts()).toEqual([]);
      const worked = turnView(ended, new Set()).find((row) => row.kind === "worked")!;
      await show(ended, new Set([worked.id]));
      expect(texts()).toEqual(["Read a file, ran a command"]);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux shell calls", () => {
  /// A shell call opens to its Shell block; Codex's MCP calls also say "execute" but run no
  /// command, so they open to the plain output.
  test("a shell call opens to the Shell block and an MCP call to plain output", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const items = [
      {
        kind: "tool",
        text: "Run bun test",
        tool: {
          id: "s",
          title: "Run bun test",
          kind: "execute",
          status: "failed",
          command: "bun test",
          exitCode: 1,
          output: "1 fail",
        },
      },
      {
        kind: "tool",
        text: "mcp.cua_repl.js",
        tool: { id: "m", title: "mcp.cua_repl.js", kind: "execute", status: "completed", output: "{ apps: [] }" },
      },
    ];
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: [{ id: "a", version: 1, at: 1, kind: "activity", items }],
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      const rows = [...dom.window.document.querySelectorAll<HTMLButtonElement>(".cv-tool.is-toggle")];
      await act(async () => rows.forEach((row) => row.click()));
      const shell = dom.window.document.querySelector(".cv-shell");
      expect(shell?.textContent).toBe("Shell$ bun test1 failExit code 1");
      expect(dom.window.document.querySelector(".cv-tool-output")?.textContent).toBe("{ apps: [] }");
      expect(dom.window.document.querySelectorAll(".cv-shell")).toHaveLength(1);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux timestamp lines", () => {
  test("unknown turn times and replayed date rows leave the prompt visible without an epoch date", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      for (const at of [undefined, 0, NaN, Infinity]) {
        const user: AcpmuxRow = { id: "u", version: 1, at: 0, kind: "user", text: "Update dependencies" };
        if (at === undefined) delete (user as Partial<AcpmuxRow>).at;
        else user.at = at;
        await act(async () =>
          root.render(
            createElement(VirtualTranscript, {
              rows: [...turnView([user], new Set()), { ...user, id: "date-replay", kind: "date" }],
              onToggleActivity: () => {},
              expanded: new Set<string>(),
            }),
          ),
        );
        expect(dom.window.document.querySelector("time.cv-date-line")).toBeNull();
        expect(dom.window.document.body.textContent).toContain("Update dependencies");
      }
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A turn that starts over an hour after the last answer gets a date; the pane showed no
  /// date at all.
  test("a turn over an hour after the previous answer draws its time above it", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const at = Date.now() - 20 * 60_000;
    const rows: AcpmuxRow[] = [
      { id: "u", version: 1, at: at - 3 * 36e5, kind: "user", text: "find SOTA harness research" },
      { id: "a", version: 1, at: at - 3 * 36e5 + 60_000, kind: "assistant", text: "RLMs lead." },
      { id: "u2", version: 1, at, kind: "user", text: "and since then?" },
    ];
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, {
            rows: turnView(rows, new Set()),
            onToggleActivity: () => {},
            expanded: new Set<string>(),
          }),
        ),
      );
      // One over the thread's first prompt (over an hour old), one over the late prompt.
      const lines = [...dom.window.document.querySelectorAll("time.cv-date-line")];
      expect(lines.map((line) => line.getAttribute("datetime"))).toEqual([
        new Date(at - 3 * 36e5).toISOString(),
        new Date(at).toISOString(),
      ]);
      // "Today", or "Yesterday" when the test runs just after midnight.
      expect(lines[1]!.textContent).toMatch(/^(Today|Yesterday) \d{1,2}:\d{2}\s[AP]M$/);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux edit diffs", () => {
  /// An edit inside an opened "Worked for" was a dead row: it now opens to the change.
  test("an edit in an opened fold opens to its diff", async () => {
    const restore = fakeViewport({ width: 760, height: 900 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const diff = {
      path: "/repo/Sources/Total.swift",
      oldText: "let a = 1\nlet b = 2\n",
      newText: "let a = 1\nlet b = 3\nlet c = 4\n",
    };
    const turn: AcpmuxRow[] = [
      { id: "u", version: 1, at: 1, kind: "user", text: "fix it" },
      // One call per row: two calls in a row fold into a run summary (ToolRun).
      {
        id: "e",
        version: 1,
        at: 2,
        kind: "activity",
        toolCount: 1,
        items: [
          {
            kind: "tool",
            text: "Edit Total.swift",
            tool: { id: "t1", title: "Edit Total.swift", kind: "edit", status: "completed", diffs: [diff] },
          },
        ],
      },
      { id: "c", version: 1, at: 3, kind: "assistant", text: "Now the notes." },
      {
        id: "n",
        version: 1,
        at: 4,
        kind: "activity",
        toolCount: 1,
        items: [
          {
            kind: "tool",
            text: "Edit notes",
            tool: { id: "t2", title: "Edit notes", kind: "edit", status: "completed" },
          },
        ],
      },
      { id: "a", version: 1, at: 5, kind: "assistant", text: "Done." },
      { id: "s", version: 1, at: 6, kind: "turnSummary", durationMs: 3000, toolCount: 2 },
    ];
    const open = new Set(["worked-u"]);
    try {
      await act(async () =>
        root.render(
          createElement(VirtualTranscript, { rows: turnView(turn, open), onToggleActivity: () => {}, expanded: open }),
        ),
      );
      const document = dom.window.document;
      const toggles = () => [...document.querySelectorAll<HTMLButtonElement>("button.cv-tool.is-toggle")];
      // The edit with a diff reads with its counts and opens; the one without a diff or output
      // stays a plain row under its own title.
      expect(toggles().map((button) => button.textContent)).toEqual(["Edited Total.swift+2-1"]);
      expect(document.body.textContent).toContain("Edit notes");
      expect(document.querySelector(".cv-edit-diff")).toBeNull();
      await act(async () => toggles()[0]!.click());
      const card = document.querySelector(".cv-edit-diff");
      expect(card?.querySelector(".cv-edit-diff__name")?.textContent).toBe("Total.swift");
      expect(card?.querySelector(".cv-edit-diff__add")?.textContent).toBe("+2");
      expect(card?.querySelector(".cv-edit-diff__del")?.textContent).toBe("-1");
      expect(card?.querySelector(".cv-edit-diff__body")?.children.length).toBe(1);
      expect(toggles()[0]!.getAttribute("aria-expanded")).toBe("true");
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux hunk review", () => {
  test("rejected hunks go to the agent as one revert prompt, and are marked requested", async () => {
    const { DiffPanel } = await import("./DiffPanel");
    const { turnFiles } = await import("./diff");
    const files = turnFiles([
      {
        id: "activity-1",
        version: 1,
        at: 1,
        kind: "activity",
        items: [
          {
            kind: "tool",
            text: "Edit",
            tool: {
              id: "t1",
              title: "Edit",
              kind: "edit",
              status: "completed",
              diffs: [{ path: "/repo/a.ts", oldText: "one\ntwo\n", newText: "one\n2\n", line: 4 }],
            },
          },
        ],
      },
    ]);
    const root = createRoot(dom.window.document.getElementById("root")!);
    const decisions = new Map<string, "accepted" | "rejected" | "requested">();
    const sent: { keys: string[]; prompt: string }[] = [];
    const render = () =>
      root.render(
        createElement(DiffPanel, {
          files,
          onClose: () => {},
          review: {
            decisions: new Map(decisions),
            decide: (key: string, decision?: "accepted" | "rejected" | "requested") => {
              if (decision) decisions.set(key, decision);
              else decisions.delete(key);
              void act(async () => render());
            },
            requestRevert: (keys: string[], prompt: string) => {
              sent.push({ keys, prompt });
              for (const key of keys) decisions.set(key, "requested");
              void act(async () => render());
            },
          },
        }),
      );
    const document = dom.window.document;
    const click = (node: Element) =>
      act(async () => {
        node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      });
    try {
      await act(async () => render());
      for (let tries = 0; tries < 50 && !document.querySelector(".acpmux-hunk-reject"); tries += 1)
        await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(document.querySelector(".acpmux-hunk-reject")?.getAttribute("aria-label")).toBe(
        "Reject change at a.ts line 5",
      );
      await click(document.querySelector(".acpmux-hunk-reject")!);
      expect(document.querySelector(".acpmux-hunk-actions")?.textContent).toBe("RejectedUndo");
      // The pressed button is gone; focus moves to the Undo that replaced it.
      expect(document.activeElement?.textContent).toBe("Undo");
      expect(document.querySelector(".acpmux-revert-count")?.textContent).toBe("1 change rejected");
      await click([...document.querySelectorAll(".acpmux-revert-send")][0]);
      expect(sent.length).toBe(1);
      expect(sent[0].prompt).toContain("--- /repo/a.ts\n+++ /repo/a.ts\n@@ -4,2 +4,2 @@\n one\n-two\n+2");
      expect(document.querySelector(".acpmux-hunk-actions")?.textContent).toBe("Revert requested");
      expect(document.querySelector(".acpmux-revert-bar")).toBeNull();
      expect(document.activeElement?.getAttribute("aria-label")).toBe("Back to transcript");
    } finally {
      await act(async () => root.unmount());
    }
  });
});
