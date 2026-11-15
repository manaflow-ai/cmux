// l10n-allow-file: test fixtures.
// Leo 2026-11-15: "what is our terminal/gui switch lol its not good enough to ship as is it doesnt
// have the composer or anything?" A chat Toggle Terminal and Chat handed to a cmux terminal keeps
// its composer: Send, Stop and its attachments go into that terminal's harness (acpmux
// hub/bridge.rs, hub/terminal_input.rs). Its model and mode chips cannot apply there (the
// terminal's harness runs its own, and a pick would start this chat's own harness): the row says
// where they are set instead of offering a pick that fails. Any other chat keeps its chips. The
// real chat composer chips, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

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

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Summary = NonNullable<Snapshot["summary"]>;

async function chat(summary: Partial<Summary>): Promise<Snapshot> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: harness.models.map((model) => ({ id: model.id, name: model.name })),
    })),
    summary: {
      sessionId: "s1",
      harness: "claude",
      family: "claude",
      model: "claude-opus-5-5",
      turnCount: 3,
      modes: {
        currentModeId: "default",
        availableModes: [
          { id: "default", name: "Default" },
          { id: "acceptEdits", name: "Accept edits" },
        ],
      },
      ...summary,
    } as Summary,
  } as Snapshot;
}

async function render(snapshot: Snapshot) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
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

const pickers = () => host.querySelectorAll(".acpmux-model, .acpmux-access, .acpmux-effort").length;
const note = () => host.querySelector("[data-terminal-pickers]")?.textContent ?? "";
const why = () => host.querySelector("[data-terminal-pickers]")?.getAttribute("title") ?? "";

test("a chat its terminal runs says where its model and mode are set, with no pick that fails", async () => {
  await render(await chat({ watching: "claude", bridged: true, terminal: true }));
  expect(pickers()).toBe(0);
  // The picked look (TerminalPickersNote.tsx): a short badge, the whole sentence its tooltip and
  // accessible description.
  expect(note()).toBe("Set in terminal");
  expect(why()).toBe("Model and mode are set in the terminal running this chat");
  const badge = host.querySelector("[data-terminal-pickers]");
  expect(badge?.getAttribute("aria-description")).toBe(why());
  expect(badge?.closest("button")).toBeNull();
});

test("a chat acpmux runs, or a desktop bridge watch, keeps its model and mode chips", async () => {
  await render(await chat({}));
  expect(pickers()).toBeGreaterThan(0);
  expect(note()).toBe("");
  await render(await chat({ watching: "claude", bridged: true }));
  expect(note()).toBe("");
});
