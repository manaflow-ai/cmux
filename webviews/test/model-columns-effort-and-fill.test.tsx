// https://github.com/manaflow-ai/cmux/issues/38173. The model button's menu, as a started chat draws
// it (the columns menu: harness rail, models, Effort), at the composer's boundary: the real picker,
// the real model menu stylesheet and a host that records what the pane sends.
//
// - An effort pick, for Codex (`reasoning_effort`) and Claude Code (`effort`), sends the session's own
//   option id and moves the Effort column's check to the picked level.
// - The menu takes the model menu's legible fill (modelPicker.css: the --surface-text-min tint and the
//   menus' frost). Before, only the list menu (.acpmux-quick-menu) had it, so the columns menu drew as
//   a plain popover (70% tint) and the composer and its chips read through its rows.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

// The first render imports the whole picker (cold, about 10 s on a busy host).
setDefaultTimeout(60_000);

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "PointerEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  // A popover update left outside act() queues React scheduler work on setImmediate; let it run
  // while the JSDOM globals still exist, or it throws "window is not defined" between tests.
  for (let turn = 0; turn < 3; turn += 1) await new Promise((resolve) => setImmediate(resolve));
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function press(element: Element) {
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
    element.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
}

const menus = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-cols")];
/// Yields to React until `ready()` holds; fails after 10 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 10_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  }
}

const harnesses = [
  { harness: "codex", optionId: "reasoning_effort", model: "gpt-6.1-sol", modelName: "GPT-6.1 Sol" },
  { harness: "claude", optionId: "effort", model: "claude-opus-5-5", modelName: "Opus 5.5" },
] as const;

async function renderPicker(entry: (typeof harnesses)[number], sent: string[]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = (current: string) =>
    ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: [{ id: entry.harness, name: entry.harness, models: [{ id: entry.model, name: entry.modelName }] }],
      summary: {
        sessionId: "s1",
        harness: entry.harness,
        model: entry.model,
        turnCount: 1,
        configOptions: [
          {
            id: entry.optionId,
            name: "Reasoning",
            category: "thought_level",
            currentValue: current,
            options: ["default", "low", "medium", "high", "xhigh", "max", "ultra"].map((value) => ({ value })),
          },
        ],
      },
    }) as Snapshot;
  const client = new QueryClient();
  const render = (current: string) =>
    root!.render(
      <QueryClientProvider client={client}>
        <ComposerPickers
          snapshot={snapshot(current)}
          onModel={(model) => sent.push(`model=${model}`)}
          onMode={() => undefined}
          onEffort={(configId, value) => sent.push(`${configId}=${value}`)}
          onHarness={() => undefined}
          // A started chat that can fork draws the columns menu (the one in the report).
          fork
          showPlan={false}
        />
      </QueryClientProvider>,
    );
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => render("low"));
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await until(() => menus().length > 0, "the model menu");
  return render;
}

const tuneRows = () => [...(menus()[0]?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]') ?? [])];
const checked = () =>
  tuneRows()
    .filter((row) => row.getAttribute("aria-checked") === "true")
    .map((row) => row.querySelector(".acpmux-cols-name")?.textContent);

for (const entry of harnesses)
  test(`${entry.harness}: an effort pick sends ${entry.optionId} and the check moves to it`, async () => {
    const sent: string[] = [];
    const render = await renderPicker(entry, sent);
    expect(checked()).toEqual(["Low"]);
    for (const [label, value] of [
      ["Medium", "medium"],
      ["Ultra", "ultra"],
      ["High", "high"],
    ] as const) {
      const row = tuneRows().find((item) => item.querySelector(".acpmux-cols-name")?.textContent === label);
      expect(row, label).toBeDefined();
      const before = sent.length;
      await act(async () => press(row!));
      await until(() => sent.length > before, `the pick of ${label}`);
      expect(sent.at(-1)).toBe(`${entry.optionId}=${value}`);
      expect(checked()).toEqual([label]);
      // The session reports the level it now runs: the check stays on it.
      await act(async () => render(value));
      expect(checked()).toEqual([label]);
    }
    expect(sent.filter((line) => line.startsWith("model="))).toEqual([]);
  });

test("the columns menu takes the model menu's legible fill", async () => {
  await renderPicker(harnesses[0], []);
  const popup = menus()[0]!;
  expect(popup.matches(".ui-popup.ui-glass")).toBe(true);
  const { readFileSync } = await import("node:fs");
  const style = dom.window.document.createElement("style");
  style.textContent = readFileSync(new URL("../src/agent-session/acpmux/modelPicker.css", import.meta.url), "utf8");
  dom.window.document.head.append(style);
  const rules = [...(style.sheet?.cssRules ?? [])].filter(
    (rule): rule is CSSStyleRule => "selectorText" in rule && "style" in rule,
  );
  const applies = (property: string, value: RegExp) =>
    rules.some((rule) => value.test(rule.style.getPropertyValue(property)) && popup.matches(rule.selectorText));
  // The fill a translucent surface that carries text keeps, and the menus' frost.
  expect(applies("--glass-tint", /--surface-text-min/)).toBe(true);
  expect(applies("--glass-backdrop", /--ds-glass-menu-blur/)).toBe(true);
  style.remove();
});
