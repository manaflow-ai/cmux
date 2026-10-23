// l10n-allow-file: test fixtures.
// The composer's third chip is the agent's permission mode (macOS 15 tester, 2026-10-19, on a
// company-managed Mac: "what is the third dropdown? it does not work"). A mode the agent or the
// company's managed settings refuse (Claude Code's disableBypassPermissionsMode) failed in silence:
// the chip kept showing the refused mode. Now the chip goes back to the mode in force, the refused
// row is disabled with the reason, and with nothing left to pick the chip is a plain label. Its
// tooltip says what the control is.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;

function reported(sessionId: string, currentModeId: string): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "default",
    turnCount: 0,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
    },
  };
}

async function render(summary: Summary, onMode: (modeId: string) => void | Promise<unknown>) {
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
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={onMode}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        holdsModePick
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

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));
const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();
const trigger = () => host.querySelector<HTMLElement>(".acpmux-access-trigger");
const item = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].find((row) =>
    row.textContent?.includes(name),
  );

test("the access chip's tooltip says what the control is", async () => {
  await render(reported("s1", "default"), () => undefined);
  const title = trigger()?.getAttribute("title") ?? "";
  // Claude Code's own name for its default mode (harnessModes.ts), not the reported one.
  expect(title).toContain("Manual");
  expect(title).toContain("What the agent may do without asking you");
});

test("a mode the agent refuses goes back to the mode in force and is marked refused", async () => {
  const picked: string[] = [];
  await render(reported("s1", "default"), (modeId) => {
    picked.push(modeId);
    return Promise.reject(new Error("bypassPermissions is disabled by managed settings"));
  });
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await act(async () => item("Bypass permissions")!.click());
  await flush();
  expect(picked).toEqual(["bypassPermissions"]);
  // The chip shows the mode the session is really in, not the refused pick.
  expect(chipText()).toBe("Manual");
  expect(host.querySelector(".acpmux-mode")!.classList.contains("acpmux-unrestricted")).toBe(false);
  // Nothing else can be picked: the chip is a plain label, its tooltip says why.
  expect(trigger()).toBeNull();
  expect(host.querySelector(".acpmux-mode")!.getAttribute("title") ?? "").toContain("Not allowed on this Mac");
});
