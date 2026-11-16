// Lawrence 2026-11-07: "we should make it possible to search for any model in cmux model picker and
// it needs to 'just work' aka download the relevant harness". The model menu's search finds the
// models of every harness the catalog knows, also one this Mac does not have (Gemini CLI) and one
// whose models only its own probe names once it runs (OpenCode: the feed's OpenCode Zen and Go
// models). A pick of one installs its CLI in place, with the progress in the menu and on the chip
// (no terminal), signs in through the harness's login when it needs one, then starts the chat on
// the picked model. The real composer, catalog and menu, in JSDOM, over a fake app host.
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

afterEach(async () => {
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  // The page-wide setup a pick started goes with the test.
  (await import("../src/agent-session/acpmux/harnessSetup").catch(() => undefined))?.resetHarnessSetupForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
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
type Call = { method: string; params: Record<string, unknown> };

/// This Mac's acpmux: Claude Code and Codex only. Gemini CLI and OpenCode are not installed.
async function installedCatalog(extra: Snapshot["catalog"] = []): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return [
    ...BUNDLED_MODEL_CATALOG.harnesses
      .filter((harness) => harness.id === "claude" || harness.id === "codex")
      .map((harness) => ({
        id: harness.id,
        name: harness.name,
        family: harness.families[0],
        models: harness.models.map((model) => ({ id: model.id, name: model.name })),
      })),
    ...extra,
  ] as Snapshot["catalog"];
}

/// Gemini CLI as acpmux lists it once its CLI is on PATH.
async function geminiListed(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const gemini = BUNDLED_MODEL_CATALOG.harnesses.find((harness) => harness.id === "gemini")!;
  return installedCatalog([
    {
      id: "gemini",
      name: gemini.name,
      family: "gemini",
      models: gemini.models.map((model) => ({ id: model.id, name: model.name })),
    } as Snapshot["catalog"][number],
  ]);
}

function newChat(catalog: Snapshot["catalog"]): Snapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: { sessionId: "s1", harness: "claude", model: "claude-opus-5-5", turnCount: 0 },
  } as Snapshot;
}

/// A deferred value a fake host call waits on, so a test can look at the menu mid-install.
function gate() {
  let open!: () => void;
  const opened = new Promise<void>((resolve) => (open = resolve));
  return { open, opened };
}

/// A New Tab's composer on the fake host `answer`. `relist` swaps acpmux's harness list (its
/// rescan after an install).
async function mount(answer: (call: Call, relist: (next: Snapshot["catalog"]) => void) => unknown) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { setNativeHost } = await import("../src/agent-session/acpmux/native");
  const { useState } = await import("react");
  const calls: Call[] = [];
  const switched: { harness: string; model?: string }[] = [];
  let relist: (next: Snapshot["catalog"]) => void = () => undefined;
  setNativeHost(async (method, params) => {
    calls.push({ method, params });
    // The bundled catalog stands in for the host's (an app without `models.catalog`).
    if (method === "models.catalog") return {};
    return answer({ method, params }, (next) => act(() => relist(next)));
  });
  const first = await installedCatalog();
  function Host() {
    const [catalog, setCatalog] = useState(first);
    relist = setCatalog;
    const snapshot = newChat(catalog);
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        catalogRefresh={{ refresh: picker.refresh }}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness, model) => switched.push({ harness, ...(model ? { model } : {}) })}
        harnessesListed
        startsChat
        setupPollMs={5}
        showPlan={false}
      />
    );
  }
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    ),
  );
  return { calls, switched };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const menu = () => doc().querySelector<HTMLElement>(".acpmux-cols");
const nameOf = (row: Element) => row.querySelector(".acpmux-cols-name")?.textContent ?? "";
const rows = () => [...(menu()?.querySelectorAll<HTMLElement>('[role="listbox"] [role="option"]') ?? [])];
const rowNames = () => rows().map(nameOf);
/// The search's headings: one per harness family, in the order the menu lists them.
const groupNames = () =>
  [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-cols-group") ?? [])].map((group) => group.textContent ?? "");
/// The search's top match.
const topMatch = () => rows()[0]!;
const chip = () => host.querySelector<HTMLElement>('[data-menu="Model"]')!;
/// The menu's setup strip: what the pick of a model whose harness needs setting up is doing.
const strip = () => menu()?.querySelector<HTMLElement>(".acpmux-cols-setup") ?? null;

async function click(element: HTMLElement) {
  await act(async () => element.click());
  await settle();
}
const open = () => click(chip());
const field = () => menu()!.querySelector<HTMLInputElement>(".acpmux-cols-search input[type=search]")!;
async function search(text: string) {
  await act(async () => {
    const input = field();
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await settle();
}
/// Yields to the page until `ready` holds, failing once `ms` have passed without it.
async function until(ready: () => boolean, ms = 5000) {
  const ends = Date.now() + ms;
  while (!ready() && Date.now() < ends) await settle();
  expect(ready()).toBe(true);
}

test("the search finds the models of a harness this Mac does not have", async () => {
  await mount(() => ({}));
  await open();
  await search("gemini 3.8 flash");
  // Its vendor's own CLI leads: the harnesses a pick installs come before those that only serve the
  // model (OpenCode), and those no pick installs come last.
  expect(groupNames()[0]).toBe("Gemini CLINot installed");
  expect(rowNames()[0]).toBe("3.8 Flash");
  // OpenCode's probe names its models only once it runs: until then the feed's OpenCode Zen and Go
  // models stand in, so an open model such as DeepSeek is found too.
  await search("deepseek v4.1 flash");
  expect(rowNames().some((name) => name.startsWith("DeepSeek V4.1 Flash"))).toBe(true);
});

test("picking a model of a harness that is not installed installs it in place, then starts the chat on it", async () => {
  const { INSTALL_COMMANDS } = await import("../src/agent-session/acpmux/harnesses/harnessRows");
  const installed = gate();
  const listed = await geminiListed();
  const { calls, switched } = await mount(async ({ method, params }, relist) => {
    if (method === "shell.run") return { id: "run-1" };
    if (method === "shell.read") {
      await installed.opened;
      return { output: "added 1 package in 3s\n", next: 1, exit: { code: 0 } };
    }
    if (method === "harness.health") {
      // acpmux's rescan finds the new CLI.
      if (params.rescan) relist(listed);
      return { health: { id: "gemini", auth: "signedIn" } };
    }
    return {};
  });
  await open();
  await search("gemini 3.8 flash");
  await click(topMatch());
  // The install runs in place (no terminal tab), and the menu and the chip say so.
  expect(calls.find((call) => call.method === "shell.run")?.params.command).toBe(INSTALL_COMMANDS.gemini);
  expect(calls.some((call) => call.method === "tab.open")).toBe(false);
  await until(() => strip()?.textContent?.includes("Installing Gemini CLI") === true);
  expect(chip().textContent).toContain("Installing Gemini CLI");
  expect(switched).toEqual([]);
  installed.open();
  await until(() => switched.length > 0);
  expect(switched).toEqual([{ harness: "gemini", model: "gemini-3.8-flash" }]);
  expect(calls.some((call) => call.method === "harness.health" && call.params.rescan === true)).toBe(true);
  await until(() => strip() === null);
});

test("a harness that installs signed out signs in through its login, then starts the chat", async () => {
  const listed = await geminiListed();
  let signedIn = false;
  const { calls, switched } = await mount(async ({ method, params }, relist) => {
    if (method === "shell.run") return { id: "run-1" };
    if (method === "shell.read") return { output: "done\n", next: 1, exit: { code: 0 } };
    if (method === "tab.open") {
      signedIn = true;
      return {};
    }
    if (method === "harness.health") {
      if (params.rescan) relist(listed);
      return { health: { id: "gemini", auth: signedIn ? "signedIn" : "signedOut", login: "gemini auth login" } };
    }
    return {};
  });
  await open();
  await search("gemini 3.8 flash");
  await click(topMatch());
  // The install spent the click: the login's terminal waits for the person's own Sign In.
  await until(() => strip()?.querySelector("button") != null);
  expect(switched).toEqual([]);
  const signIn = [...strip()!.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
    button.textContent?.includes("Sign In"),
  )!;
  await click(signIn);
  const login = calls.find((call) => call.method === "tab.open")!;
  expect(login.params).toMatchObject({ kind: "terminal", text: "gemini auth login", run: true });
  await until(() => switched.length > 0);
  expect(switched).toEqual([{ harness: "gemini", model: "gemini-3.8-flash" }]);
});

test("a failed install says why in the menu and starts nothing", async () => {
  const { calls, switched } = await mount(async ({ method }) => {
    if (method === "shell.run") return { id: "run-1" };
    if (method === "shell.read") return { output: "npm ERR! network unreachable\n", next: 1, exit: { code: 1 } };
    return {};
  });
  await open();
  await search("gemini 3.8 flash");
  await click(topMatch());
  await until(() => strip()?.textContent?.includes("npm ERR! network unreachable") === true);
  expect(switched).toEqual([]);
  expect(calls.some((call) => call.method === "harness.health")).toBe(false);
});
