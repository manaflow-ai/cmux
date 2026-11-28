import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

// VirtualTranscript reaches into browser layout and the Pierre web components while rendering. Keep
// this focused test's DOM harness local so it can exercise the real transcript without restoring the
// large deleted transcript fixture suite.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
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
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(_callback: () => void) {}
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

function fakeViewport(size: { width: number; height: number }) {
  const prototype = dom.window.HTMLElement.prototype;
  const viewportKeys = ["clientHeight", "clientWidth", "scrollHeight", "scrollTop"] as const;
  const previousDescriptors = new Map(
    viewportKeys.map((key) => [key, Object.getOwnPropertyDescriptor(prototype, key)] as const),
  );
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
    for (const key of viewportKeys) {
      const descriptor = previousDescriptors.get(key);
      if (descriptor) Object.defineProperty(prototype, key, descriptor);
      else delete (prototype as unknown as Record<string, unknown>)[key];
    }
  };
}

const conversation: AcpmuxRow[] = [
  { id: "selection-1", version: 1, at: 1, kind: "user", text: "first prompt" },
  {
    id: "selection-2",
    version: 1,
    at: 2,
    kind: "assistant",
    text: "second reply",
  },
  {
    id: "selection-3",
    version: 1,
    at: 3,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "Run tests",
        tool: {
          id: "tool-1",
          title: "Run tests",
          status: "completed",
          output: "ok",
        },
      },
    ],
  },
];
const expectedCopy = "first prompt\n\nsecond reply\n\nRun tests\nok";

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) if (!saved.some(([savedKey]) => savedKey === key)) delete globals[key];
  dom.window.close();
});

test("keyboard transcript selection copies source and reports copy success or failure", async () => {
  const restore = fakeViewport({ width: 760, height: 600 });
  const root = createRoot(dom.window.document.getElementById("root")!);
  const copied: string[] = [];
  const clipboard = Object.getOwnPropertyDescriptor(globalThis.navigator, "clipboard");
  const execCommand = Object.getOwnPropertyDescriptor(dom.window.document, "execCommand");
  Object.defineProperty(globalThis.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  const key = (node: HTMLElement, init: KeyboardEventInit) =>
    act(async () => {
      node.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          ...init,
        }),
      );
    });
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={conversation}
          sessionId="session-one"
          onToggleActivity={() => {}}
          expanded={new Set<string>()}
        />,
      ),
    );
    const row = (id: string) => dom.window.document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
    const focusTarget = (id: string) => row(id).querySelector<HTMLButtonElement>(".acpmux-row__copy") ?? row(id);
    row("selection-1").focus();
    await key(row("selection-1"), { key: "ArrowDown", shiftKey: true });
    await key(focusTarget("selection-2"), { key: "ArrowDown", shiftKey: true });
    expect(row("selection-1").getAttribute("data-transcript-selected")).toBe("true");
    expect(row("selection-3").getAttribute("data-transcript-selected")).toBe("true");

    // Both platform modifiers use the same range and source serialization.
    await key(focusTarget("selection-3"), { key: "c", ctrlKey: true });
    await key(focusTarget("selection-3"), { key: "c", metaKey: true });
    await flush();
    expect(copied).toEqual([expectedCopy, expectedCopy]);

    const copyButton = row("selection-3").querySelector<HTMLButtonElement>(".acpmux-row__copy")!;
    await act(async () => copyButton.click());
    await flush();
    expect(copyButton.getAttribute("aria-label")).toBe("Copied");
    expect(copied.at(-1)).toBe(expectedCopy);

    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: { writeText: async () => Promise.reject(new Error("denied")) },
    });
    Object.defineProperty(dom.window.document, "execCommand", {
      configurable: true,
      value: () => false,
    });
    await act(async () => copyButton.click());
    await flush();
    expect(copyButton.getAttribute("aria-label")).toBe("Copy");
  } finally {
    await act(async () => root.unmount());
    if (clipboard) Object.defineProperty(globalThis.navigator, "clipboard", clipboard);
    else delete (globalThis.navigator as unknown as Record<string, unknown>).clipboard;
    if (execCommand) Object.defineProperty(dom.window.document, "execCommand", execCommand);
    else delete (dom.window.document as unknown as Record<string, unknown>).execCommand;
    restore();
  }
});
