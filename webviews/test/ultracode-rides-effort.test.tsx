// Review of #20592: Ultracode rides the session's free effort option (effort=ultracode /
// effort=xhigh). A pick on acpmux's own `ultracode` id is a mode switch the app confirms with a
// sheet, and a non-person pane is refused it. Since Leo 2026-10-20 the composer has one model button
// and Ultracode is the last level of its menu's Effort ›; the button names it while it is on. At the
// composer's boundary: the real picker and a host that records what the pane sends.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

afterAll(() => {
  act(() => root?.unmount());
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

/// What the pickers sent (`configId=value`), in order.
const sent: string[] = [];
const menus = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  }
}

/// Opens the model button's menu, then its Effort ›, and picks the level named `label`.
async function pick(label: string) {
  if (menus().length === 0)
    await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await until(() => menus().length > 0, "the model menu");
  const effort = [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Effort"),
  );
  expect(effort, "the Effort row").toBeDefined();
  const open = menus().length;
  await act(async () => effort!.click());
  await until(() => menus().length > open, "the Effort submenu");
  const items = () => [...menus().at(-1)!.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
  const row = items().find((item) => item.textContent?.replace("✓", "").trim() === label);
  expect(
    row,
    `row ${label} in ${items()
      .map((item) => item.textContent)
      .join(" | ")}`,
  ).toBeDefined();
  const picked = sent.length;
  await act(async () => press(row!));
  await until(() => sent.length > picked, `the pick of ${label}`);
}

test("Ultracode on and off ride the free effort option, never acpmux's ultracode id", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = (ultracode: string) =>
    ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: [],
      summary: {
        sessionId: "s1",
        harness: "claude",
        model: "claude-opus-5-5",
        turnCount: 1,
        configOptions: [
          {
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: ultracode === "on" ? "xhigh" : "medium",
            options: ["default", "low", "medium", "high", "xhigh", "max"].map((value) => ({ value })),
          },
          {
            id: "ultracode",
            name: "Ultracode",
            category: "model_config",
            currentValue: ultracode,
            options: [{ value: "off" }, { value: "on" }],
          },
        ],
      },
    }) as Snapshot;
  const render = (ultracode: string) =>
    root!.render(
      <QueryClientProvider client={client}>
        <ComposerPickers
          snapshot={snapshot(ultracode)}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={(configId, value) => sent.push(`${configId}=${value}`)}
          onHarness={() => undefined}
          showPlan={false}
        />
      </QueryClientProvider>,
    );
  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => render("off"));
  await pick("Ultracode");
  await act(async () => render("on"));
  // The button names Ultracode while it is on, never the word Reasoning.
  const button = host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
  expect(button.textContent).toContain("Ultracode");
  expect(button.textContent).not.toContain("Reasoning");
  await pick("Extra High");
  expect(sent).toEqual(["effort=ultracode", "effort=xhigh"]);
});
