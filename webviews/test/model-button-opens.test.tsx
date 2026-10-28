// Leo 2026-10-21 on nightly 3a63d6d: in his long claude-sr2 chat, clicking the "Opus 5.5  Medium"
// model button did nothing. The model button (and every ui/Menu chip) opens on the mouse press
// (pointerdown). When the browser then delivers the press's mousedown after React has drawn the
// open menu (WebKit dispatches a mousedown after a pointerdown, ui/Menu.tsx), Base UI's own
// mousedown toggle read the menu as open and closed it again a frame later: the menu flashed and
// was gone. This holds the menu open through that press, in the long running chat's state, and a
// second press still closes it. The real composer pickers and catalog, in JSDOM.
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
  dom = new JSDOM("<!doctype html><div class=acpmux-main><div id=root></div></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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

afterEach(() => {
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

/// Leo's chat: a claude-sr2 chat 704 turns in, its turn running, a long transcript and a queued prompt.
async function mountLongChat() {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const models = [
    { id: "default", name: "Default" },
    { id: "claude-opus-5-5", name: "Opus 5.5" },
    { id: "claude-sonnet-5", name: "Sonnet 5" },
  ];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: Array.from({ length: 60 }, (_, index) => ({ kind: "user", id: `u${index}`, text: `turn ${index}` })),
    sessions: [],
    connection: "tool_call",
    isWorking: true,
    queue: [{ id: "q1", text: "THEN HOW DID YOUR THINKING GET REMOVED" }],
    canLoadOlder: true,
    catalog: [
      { id: "claude", name: "Claude Code", family: "claude", models },
      { id: "claude-sr2", name: "Claude Code (sr2 internal)", family: "claude-sr2", models },
    ],
    summary: {
      sessionId: "s1",
      harness: "claude-sr2",
      family: "claude-sr2",
      model: "claude-opus-5-5",
      turnCount: 704,
      usage: { size: 1_000_000, used: 300_446 },
      modes: {
        availableModes: [
          { id: "default", name: "Normal" },
          { id: "bypassPermissions", name: "Full access" },
        ],
        currentModeId: "bypassPermissions",
      },
      configOptions: [
        {
          id: "effort",
          name: "Reasoning",
          category: "thought_level",
          currentValue: "medium",
          options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
        },
      ],
    },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(
      snapshot.catalog,
      { harness: "claude-sr2", configOptions: snapshot.summary?.configOptions },
      snapshot.sessions,
    );
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        showPlan={false}
        harnessesListed
      />
    );
  }
  root = createRoot(host);
  const client = new QueryClient();
  await act(async () =>
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    ),
  );
}

const modelButton = () => host.querySelector<HTMLButtonElement>('.acpmux-model button[data-menu="Model"]')!;
const menu = () => dom.window.document.querySelector<HTMLElement>(".acpmux-quick-menu");
/// The next painted frame: Base UI's mousedown toggle lands in one.
const nextFrame = () =>
  act(async () => {
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
  });

/// A mouse click as WebKit delivers it: pointerdown, then (React has drawn by now) the mousedown
/// that follows it, pointerup, mouseup and the click.
async function click(button: HTMLElement) {
  const View = dom.window as unknown as { PointerEvent?: typeof MouseEvent; MouseEvent: typeof MouseEvent };
  const pointer = (type: string) => {
    const event = new (View.PointerEvent ?? View.MouseEvent)(type, { bubbles: true, cancelable: true, button: 0 });
    for (const [key, value] of Object.entries({ pointerType: "mouse", pointerId: 1, isPrimary: true }))
      Object.defineProperty(event, key, { value });
    return event;
  };
  const mouse = (type: string, detail = 0) =>
    new View.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, detail });
  await act(async () => void button.dispatchEvent(pointer("pointerdown")));
  await act(async () => void button.dispatchEvent(mouse("mousedown")));
  await act(async () => void button.dispatchEvent(pointer("pointerup")));
  await act(async () => void button.dispatchEvent(mouse("mouseup")));
  await act(async () => void button.dispatchEvent(mouse("click", 1)));
  await nextFrame();
}

test("the model button opens its menu in a long running chat, and the menu stays open", async () => {
  await mountLongChat();
  expect(modelButton().textContent).toContain("Opus 5.5");
  await click(modelButton());
  expect(modelButton().getAttribute("aria-expanded")).toBe("true");
  expect(menu()?.querySelector(".ui-menu-group-label")).toBeNull();
  // Still open a frame later: nothing closes it behind the press.
  await nextFrame();
  expect(modelButton().getAttribute("aria-expanded")).toBe("true");
  expect(menu()).not.toBeNull();
});

test("a second press on the model button closes its menu, and it stays closed", async () => {
  await mountLongChat();
  await click(modelButton());
  expect(modelButton().getAttribute("aria-expanded")).toBe("true");
  await click(modelButton());
  await nextFrame();
  expect(modelButton().getAttribute("aria-expanded")).toBe("false");
});

test("every ui/Menu chip holds open through the press's mousedown", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Menu, MenuButton, MenuItem, MenuPopup } = await import("../src/ui/Menu");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Menu>
        <MenuButton className="plain-chip">Open</MenuButton>
        <MenuPopup className="plain-menu">
          <MenuItem>One</MenuItem>
        </MenuPopup>
      </Menu>,
    ),
  );
  const button = host.querySelector<HTMLElement>(".plain-chip")!;
  await click(button);
  await nextFrame();
  expect(button.getAttribute("aria-expanded")).toBe("true");
  await click(button);
  await nextFrame();
  expect(button.getAttribute("aria-expanded")).toBe("false");
});
