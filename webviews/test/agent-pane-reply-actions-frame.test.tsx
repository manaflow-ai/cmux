// l10n-allow-file: test fixtures, not shipped UI.
// A completed turn renders one footer, even when its interim dialogue is expanded.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const observers = new Set<{
  targets: Set<Element>;
  notify: (entries: { target: Element }[]) => void;
}>();
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // Kept, so a test can tell the transcript a row's size changed as the browser would.
  ResizeObserver: class {
    targets = new Set<Element>();
    constructor(readonly notify: (entries: { target: Element }[]) => void) {
      observers.add(this);
    }
    observe(target: Element) {
      this.targets.add(target);
    }
    unobserve(target: Element) {
      this.targets.delete(target);
    }
    disconnect() {
      observers.delete(this);
    }
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get: () => 10_000,
});
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 760,
});

// jsdom draws nothing: a row has the height set here, and none (unmeasured) otherwise.
const drawn = new Map<string, number>();
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = drawn.get(this.dataset.rowId ?? "") ?? 0;
  return {
    x: 0,
    y: 0,
    top: 0,
    left: 0,
    right: 760,
    bottom: height,
    width: 760,
    height,
    toJSON() {},
  } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { turnView, WORKED } = await import("../src/agent-session/acpmux/conversation/turns");
const source = [
  { id: "u1", version: 1, at: 0, kind: "user", text: "Check the change." },
  { id: "a1", version: 1, at: 1_000, kind: "assistant", text: "Checking now." },
  {
    id: "t1",
    version: 1,
    at: 2_000,
    kind: "activity",
    toolCount: 1,
    items: [
      {
        kind: "tool",
        text: "git status",
        tool: {
          id: "c1",
          title: "git status",
          kind: "execute",
          status: "completed",
          command: "git status",
        },
      },
    ],
  },
  { id: "a2", version: 1, at: 3_000, kind: "assistant", text: "The check passed." },
  {
    id: "f1",
    version: 1,
    at: 4_000,
    kind: "turnSummary",
    durationMs: 4_000,
    toolCount: 1,
    status: "completed",
  },
];

test("several assistant messages and tool calls render exactly one footer at the turn end", async () => {
  for (const opened of [false, true]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const expanded = new Set(opened ? [`${WORKED}-u1`] : []);
    const rows = turnView(source, expanded, { now: 10_000 });
    try {
      await act(async () =>
        root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={expanded} />),
      );
      const document = dom.window.document;
      expect(document.querySelector('[data-row-id="a2"]')).not.toBeNull();
      if (opened) expect(document.querySelector('[data-row-id="a1"]')).not.toBeNull();
      expect(document.querySelectorAll(".cv-turn-actions").length).toBe(1);
      expect(document.querySelectorAll(".cv-reply-actions").length).toBe(0);
      const footer = document.querySelector('[data-row-id="f1"]')!;
      expect(footer.querySelectorAll(".cv-turn-actions").length).toBe(1);
      expect(footer.querySelectorAll('[aria-label="Copy"]').length).toBe(1);
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("a personal steer keeps reply A and final reply B expanded while other chatter collapses", async () => {
  for (const steered of [false, true]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const expanded = new Set<string>();
    const rows = turnView(
      [
        source[0]!,
        source[1]!,
        ...(steered
          ? [
              {
                id: "steer",
                version: 1,
                at: 1_500,
                kind: "user",
                text: "Also check retries.",
                steer: "landed" as const,
              },
            ]
          : []),
        source[2]!,
        { id: "interim", version: 1, at: 2_500, kind: "assistant", text: "Checking retries next." },
        { ...source[2]!, id: "t2", at: 2_600 },
        source[3]!,
        source[4]!,
      ],
      expanded,
      { now: 10_000 },
    );
    try {
      await act(async () =>
        root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={expanded} />),
      );
      const document = dom.window.document;
      expect(Boolean(document.querySelector('[data-row-id="a1"]'))).toBe(steered);
      expect(Boolean(document.querySelector('[data-row-id="steer"]'))).toBe(steered);
      expect(document.querySelector('[data-row-id="a2"]')).not.toBeNull();
      for (const id of ["t1", "interim", "t2"]) expect(document.querySelector(`[data-row-id="${id}"]`)).toBeNull();
      expect(document.querySelectorAll(".cv-turn-actions").length).toBe(1);
      expect(document.querySelectorAll(".cv-reply-actions").length).toBe(0);
    } finally {
      await act(async () => root.unmount());
    }
  }
});
