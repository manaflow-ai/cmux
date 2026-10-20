// Review of #20592: Ultracode is a switch in the Reasoning menu, but it rides the session's free
// effort option (effort=ultracode / effort=xhigh). A pick on acpmux's own `ultracode` id is a mode
// switch the app confirms with a sheet, and a non-person pane is refused it. At the composer's
// boundary: the real picker and a host that records what the pane sends.
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

async function pick(label: string) {
  const items = () => [...dom.window.document.querySelectorAll('.acpmux-effort-menu [role="menuitemradio"]')];
  if (items().length === 0) await act(async () => press(host.querySelector(".acpmux-effort .acpmux-picker-button")!));
  // The Ultracode section's rows come after the levels: its On is the first "On".
  const row = items().find((item) => item.textContent?.trim().startsWith(label));
  expect(
    row,
    `row ${label} in ${items()
      .map((item) => item.textContent)
      .join(" | ")}`,
  ).toBeDefined();
  await act(async () => press(row!));
}

test("Ultracode On and Off ride the free effort option, never acpmux's ultracode id", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const sent: string[] = [];
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
  await pick("On");
  await act(async () => render("on"));
  await pick("Off");
  expect(sent).toEqual(["effort=ultracode", "effort=xhigh"]);
});
