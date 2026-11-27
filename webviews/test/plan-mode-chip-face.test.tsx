// l10n-allow-file: test fixtures.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  const { resetStartModesForTests, setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  resetStartModesForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Summary = Record<string, unknown>;

/// A chat on an agent with no cmux mode menu of its own (an ACP agent cmux has no table for), whose
/// modes are Ask, Accept Edits and Plan, as the test agent of the fleet captures reports them.
function chat(currentModeId: string): Summary {
  return {
    sessionId: "s1",
    harness: "chipfake",
    model: "m1",
    turnCount: 1,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask" },
        { id: "acceptEdits", name: "Accept Edits" },
        { id: "plan", name: "Plan" },
      ],
    },
  };
}

async function render(summary: Summary, onMode: (modeId: string) => void | Promise<unknown> = () => undefined) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary,
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "chipfake" });
    // The app draws no Plan toggle beside the chips (App.tsx): the + menu's Plan row, /plan and
    // Toggle Plan Mode switch it.
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={onMode}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();
const trigger = () => host.querySelector<HTMLElement>(".acpmux-access-trigger");
const item = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].find((row) =>
    row.textContent?.includes(name),
  );

// The Mode chip named the mode Plan would return to ("Ask") while the chat ran Plan: with the
// app's Plan toggle gone, nothing on screen said the chat was in Plan after /plan, the + menu's
// Plan row or Toggle Plan Mode.
test("a chat in Plan names Plan on the Mode chip when no Plan toggle is drawn", async () => {
  await render(chat("default"));
  expect(chipText()).toBe("Ask");
  await render(chat("plan"));
  expect(chipText()).toBe("Plan");
  expect(trigger()?.getAttribute("title") ?? "").toContain("Plan");
  await render(chat("default"));
  expect(chipText()).toBe("Ask");
});

test("the Mode menu of a chat in Plan keeps only the permission modes, and a pick leaves Plan", async () => {
  const picked: string[] = [];
  await render(chat("plan"), (modeId) => void picked.push(modeId));
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(item("Ask")).toBeDefined();
  expect(item("Accept Edits")).toBeDefined();
  expect(item("Plan")).toBeUndefined();
  // The mode Plan returns to is a pick too: it leaves Plan, as the + menu's Build row does.
  await act(async () => item("Ask")!.click());
  expect(picked).toEqual(["default"]);
});
