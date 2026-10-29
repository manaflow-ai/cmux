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
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
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

test("a drawn reply gains its row when a steer follows it, in a paged transcript too", async () => {
  for (const canLoadOlder of [false, true]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const draw = (rows: readonly object[]) =>
      act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows as never}
            onToggleActivity={() => {}}
            expanded={new Set()}
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
