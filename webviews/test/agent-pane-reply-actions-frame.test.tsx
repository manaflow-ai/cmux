// l10n-allow-file: test fixtures, not shipped UI.
// A reply drawn before anything follows it gains its own action row when a steer arrives after it
// (model.ts hasReplyActions), even in a paged transcript, where the frame's other props stay the
// same: the frame (RowFrame) carries the flag, so it redraws and measures again. Before, the flag
// reached only the frame's children, which its memo ignores, so the reply kept no row.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const observers = new Set<{ targets: Set<Element>; notify: (entries: { target: Element }[]) => void }>();
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

// jsdom draws nothing: a row has the height set here, and none (unmeasured) otherwise.
const drawn = new Map<string, number>();
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = drawn.get(this.dataset.rowId ?? "") ?? 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 760, bottom: height, width: 760, height, toJSON() {} } as DOMRect;
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

const reply = { id: "a1", version: 1, at: 1_000, kind: "assistant", text: "I gave the team access to the helper." };
const prompt = { id: "u1", version: 1, at: 0, kind: "user", text: "Give the team access." };
const steer = { id: "s1", version: 1, at: 2_000, kind: "user", text: "Also tell Lawrence.", steer: "landed" };
// The page passes the same callbacks and set on every render. A fresh one redraws every frame
// whatever its memo says, and would hide a frame that misses the change.
const onToggleActivity = () => {};
const expanded = new Set<string>();

test("a drawn reply gains its row when a steer follows it, in a paged transcript too", async () => {
  for (const canLoadOlder of [false, true]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const draw = (rows: readonly object[]) =>
      act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows as never}
            onToggleActivity={onToggleActivity}
            expanded={expanded}
            {...(canLoadOlder ? { canLoadOlder: true, onLoadOlder: async () => {} } : {})}
          />,
        ),
      );
    const rowOf = (id: string) => dom.window.document.querySelector(`[data-row-id="${id}"]`);
    try {
      await draw([prompt, reply]);
      expect(rowOf("a1")?.querySelector(".cv-reply-actions")).toBeNull();
      await draw([prompt, reply, steer]);
      expect(rowOf("a1")?.querySelector(".cv-reply-actions")).not.toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("a reply with its row keeps the height the browser measured when it resizes", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rowOf = (id: string) => dom.window.document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
  const top = (id: string) =>
    Number.parseFloat(rowOf(id).style.top) + (Number.parseFloat(rowOf(id).style.marginTop) || 0);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={[prompt, reply, steer] as never}
          onToggleActivity={onToggleActivity}
          expanded={expanded}
        />,
      ),
    );
    expect(rowOf("a1").querySelector(".cv-reply-actions")).not.toBeNull();
    // The reply wraps taller than its estimate (a font that loads, a narrower pane).
    drawn.set("a1", 900);
    await act(async () => {
      for (const observer of observers)
        if (observer.targets.has(rowOf("a1"))) observer.notify([{ target: rowOf("a1") }]);
    });
    // The steer is placed under the reply's measured 900px, not under its estimate. Reported
    // without the reply's row flag, the height was taken for a stale one and dropped.
    expect(top("s1") - top("a1")).toBeGreaterThanOrEqual(900);
  } finally {
    drawn.clear();
    await act(async () => root.unmount());
  }
});
