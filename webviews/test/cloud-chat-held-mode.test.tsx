// l10n-allow-file: test fixtures.
// Leo 2026-11-01, on a new chat on a Cloud machine whose start the machine refused: "i couldn't
// even pick a mode for this kind aqua sandpaper one". A chat on another machine (the cloud, a
// remote host) starts with its first send, so before then its access chip was the inert "Mode"
// placeholder: no menu, no pick. Now it is a live menu whose pick goes to `chat.mode`, which holds
// it for the session the send starts (cloud-chat-held-mode-start.test.ts); once that session
// reports its modes, the agent's list is the menu. The real chat composer chips, in JSDOM.
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
  "Node",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  // The DOM constructors the menus and App's registered elements read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(() => {
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Summary = NonNullable<Snapshot["summary"]>;

async function catalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
}

/// A chat on a Cloud machine (`origin: "remote"`, the connection to that machine's acpmux): with
/// no `summary` override, a new one whose first send has not started it (or whose start failed).
async function cloudChat(summary: Partial<Summary> = {}): Promise<Snapshot> {
  return {
    type: "snapshot",
    protocolVersion: 1,
    origin: "remote",
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: await catalog(),
    summary: { sessionId: "", harness: "claude", turnCount: 0, hostKind: "cloud", ...summary } as Summary,
  } as Snapshot;
}

/// The chat's own composer chips, as the pane draws them; `calls` records what reaches the host.
async function render(snapshot: Snapshot, calls: { method: string; params: unknown }[]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  (dom.window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: (_target, method) => async (params: unknown) => void calls.push({ method: String(method), params }) },
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatComposerChips snapshot={snapshot} />
      </QueryClientProvider>,
    ),
  );
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
}

const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();
const trigger = () => host.querySelector<HTMLButtonElement>("button.acpmux-access-trigger");
const rows = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")];
const row = (name: string) => rows().find((item) => item.textContent?.includes(name));
// Microtask turns under act until the condition holds (bounded); no real timer.
async function settle(done: () => boolean) {
  for (let turn = 0; turn < 50 && !done(); turn += 1) await act(async () => await Promise.resolve());
}
async function openMenu() {
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
}

test("a Cloud chat before its first send has started it can pick a permission mode", async () => {
  const calls: { method: string; params: unknown }[] = [];
  await render(await cloudChat(), calls);
  // The chip still names no mode: the machine decides it until the chat reports one.
  expect(chipText()).toBe("Mode");
  // But it is a live menu, not the inert placeholder.
  expect(trigger()).not.toBeNull();
  await openMenu();
  expect(rows().length).toBeGreaterThan(0);
  await act(async () => row("Bypass permissions")!.click());
  await settle(() => calls.some((call) => call.method === "chat.mode"));
  expect(calls.filter((call) => call.method === "chat.mode")).toEqual([
    { method: "chat.mode", params: { modeId: "bypassPermissions" } },
  ]);
  // The chip names the pick it holds for the start.
  expect(chipText()).toBe("Bypass permissions");
});

test("once the Cloud chat's agent reports its modes, its list is the menu", async () => {
  const calls: { method: string; params: unknown }[] = [];
  await render(await cloudChat(), calls);
  await render(
    await cloudChat({
      sessionId: "cloud-1",
      modes: {
        currentModeId: "acceptEdits",
        availableModes: [
          { id: "default", name: "Default" },
          { id: "acceptEdits", name: "Accept edits" },
        ],
      },
    }),
    calls,
  );
  await openMenu();
  expect(rows().map((item) => item.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "Manual",
    "Accept edits",
  ]);
});

test("a chat on this Mac with no session and no held start keeps the inert chip", async () => {
  const calls: { method: string; params: unknown }[] = [];
  const snapshot = await cloudChat({ hostKind: undefined });
  snapshot.origin = "local";
  await render(snapshot, calls);
  // This Mac's chats hold a pick only through a New Tab start or a running switch (holdsModePick).
  expect(trigger()).toBeNull();
});
