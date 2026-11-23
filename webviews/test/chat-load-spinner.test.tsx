// l10n-allow-file: regression fixture text, not shipped UI.
// cmux#48605: a chat still reading its rows showed an empty pane with no sign it was loading.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");

afterAll(async () => {
  setPaneLanguage("en");
  await teardownDom(saved, { window: dom.window, scope });
});

const reply: AcpmuxRow = { id: "reply", kind: "assistant", version: 1, at: 2, text: "The review is complete." };
const marks = () =>
  [...document.querySelectorAll(".acpmux-transcript-loading, .acpmux-older-loading")].map((node) =>
    node.getAttribute("aria-label"),
  );

test("a chat still reading its rows shows a spinner, and the spinner goes once the rows are in", async () => {
  const root = createRoot(document.getElementById("root")!);
  const draw = (rows: AcpmuxRow[], loading: boolean) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          sessionId="chat"
          loading={loading}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  await draw([], true);
  expect(marks()).toEqual(["Loading chat…"]);
  await draw([reply], true);
  expect(marks()).toEqual([]);
  await draw([reply], false);
  expect(marks()).toEqual([]);
  expect(document.body.textContent).toContain("The review is complete.");
  await act(async () => root.unmount());
});

test("a read chat with no rows (a new chat) shows no spinner", async () => {
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript rows={[]} sessionId="new" loading={false} onToggleActivity={() => {}} expanded={new Set()} />,
    ),
  );
  expect(marks()).toEqual([]);
  await act(async () => root.unmount());
});
