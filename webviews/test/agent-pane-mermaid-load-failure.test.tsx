// A chart whose renderer never loads (user, Nov 20: "Couldn't draw this chart: ondine library failed to
// load" on the nightly, whose chat page served no `__lib/`). The reader sees plain words, never the
// renderer's internal name or a script URL, and the source stays readable below.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { join } from "node:path";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import { readFileSync } from "node:fs";

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
  Node: dom.window.Node,
  Range: dom.window.Range,
  DOMParser: dom.window.DOMParser,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
const CHART = readFileSync(join(import.meta.dir, "fixtures", "mermaid-front-door.mmd"), "utf8").trimEnd();

/// Yields to React until `ready` holds; fails after 5 s with what it waited for.
async function settleUntil(ready: () => boolean, what: string) {
  const deadline = performance.now() + 5_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

/// The library script the chart asked for, by its `__lib/` name, once it is in the document.
const libraryScript = (name: string) =>
  [...dom.window.document.head.querySelectorAll("script")].find((script) => script.src.endsWith(`__lib/${name}.js`));

test("a chart whose renderer fails to load says so in plain words and keeps the source", async () => {
  expect(scope.ondine).toBeUndefined();
  expect(scope.mermaid).toBeUndefined();
  root = createRoot(host);
  await act(async () => root!.render(<Markdown streaming={false}>{"```mermaid\n" + CHART + "\n```"}</Markdown>));
  // jsdom fetches no script: the host's 404 is the script's error event.
  for (const name of ["ondine", "mermaid"]) {
    await settleUntil(() => libraryScript(name) !== undefined, `the ${name} script`);
    libraryScript(name)!.dispatchEvent(new dom.window.Event("error"));
  }
  const diagram = host.querySelector(".cv-diagram[data-language='mermaid']");
  await settleUntil(() => diagram?.querySelector(".cv-diagram__error") != null, "the error line");
  const error = diagram!.querySelector(".cv-diagram__error")!.textContent ?? "";
  expect(error).toStartWith("Couldn't draw this chart");
  expect(error).not.toMatch(/ondine|mermaid|vega|library|__lib|\.js\b/i);
  expect(diagram!.textContent).toContain("Slack Message Read Service");
});
