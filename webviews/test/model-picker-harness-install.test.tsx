// l10n-allow-file: test fixtures.
// cmux#38191: a model of a harness this Mac does not have (Gemini CLI, with only Claude Code
// installed) is a pick in the composer's model menu. It opens an install prompt naming the harness
// and the command Install runs; Install runs it through the host with its output as progress, and
// once it ends well acpmux looks for the harness again, the catalog is read again, and the picked
// model starts (`onHarness`). A failed command says why and offers Try Again; Hide keeps the
// install running and the pick still lands. A pane with no installer (a chat on another machine)
// keeps the rows unpickable and Install… on the Harnesses page.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
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
  const { resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
  resetStartModesForTests();
});

afterAll(async () => {
  await settle();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Call = { method: string; params: Record<string, unknown> };
type Read = { output?: string; next?: number; exit?: { code?: number } };

/// A host whose `shell.read` answers come from `reads`, one per call (a pending promise holds one).
function fakeHost(reads: (Read | Promise<Read>)[], health: Record<string, unknown> = { auth: "signedIn" }) {
  const calls: Call[] = [];
  const native = async (method: string, params: Record<string, unknown> = {}) => {
    calls.push({ method, params });
    if (method === "shell.run") return { id: "run-1" };
    if (method === "shell.read") return reads.shift() ?? { exit: { code: 0 } };
    if (method === "harness.health") return { health: { id: params.id, ...health } };
    return {};
  };
  return { calls, native };
}

/// The composer chips of a new chat on a Mac that has only Claude Code, over the bundled catalog.
async function render(
  installer?: {
    native: (method: string, params?: Record<string, unknown>) => Promise<unknown>;
    refreshFails?: boolean;
  },
  composer = true,
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { HarnessInstallProvider } = await import("../src/agent-session/acpmux/harnesses/harnessInstallContext");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const catalog = BUNDLED_MODEL_CATALOG.harnesses
    .filter((entry) => entry.id === "claude")
    .map((entry) => ({
      id: entry.id,
      name: entry.name,
      family: entry.families[0],
      models: entry.models.map((model) => ({ id: model.id, name: model.name })),
    })) as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    origin: "local",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: { sessionId: "", turnCount: 0, harness: "claude" },
  } as unknown as Snapshot;
  const started: unknown[][] = [];
  let added = 0;
  let refreshed = 0;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        harnessesListed
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(...args: unknown[]) => void started.push(args)}
        onAddAgent={() => void added++}
        showPlan={false}
      />
    );
  }
  const tree = (withComposer: boolean) => (
    <QueryClientProvider client={new QueryClient()}>
      {/* The pane's provider, as App.tsx draws it: no `native` for a chat on another machine. */}
      <HarnessInstallProvider
        {...(installer ? { native: installer.native } : {})}
        refreshCatalog={async () => {
          refreshed++;
          if (installer?.refreshFails) throw new Error("models.catalog refresh failed");
        }}
      >
        {withComposer && <Host />}
      </HarnessInstallProvider>
    </QueryClientProvider>
  );
  root ??= createRoot(host);
  await act(async () => root!.render(tree(composer)));
  await settle();
  /// The composer goes away (the New Tab became a chat, the Harnesses page over it); the pane stays.
  const dropComposer = () => act(async () => root!.render(tree(false)));
  return { started, added: () => added, refreshed: () => refreshed, dropComposer };
}

const doc = () => dom.window.document;
const dialog = () => doc().querySelector<HTMLElement>(".acpmux-install-dialog");
const button = (scopeEl: ParentNode, text: string) =>
  [...scopeEl.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.startsWith(text));

/// Opens the model menu on Gemini CLI's tab and answers its Gemini 3.1 Pro Preview row.
async function geminiRow() {
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-model button")!.click());
  await settle();
  const tab = doc().querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="Gemini CLI"]')!;
  expect(tab).toBeTruthy();
  await act(async () => tab.click());
  await settle();
  const menu = doc().querySelector('.acpmux-cols [role="listbox"]')!;
  return [...menu.querySelectorAll<HTMLElement>('[role="option"]')].find((item) =>
    item.title.endsWith("gemini-3.1-pro-preview"),
  )!;
}

describe("one-click install from the model picker", () => {
  test("picking a missing harness's model installs it, then starts that model", async () => {
    const { calls, native } = fakeHost([
      { output: "added 1 package\n", next: 1 },
      { output: "changed 12 packages in 3s\n", next: 2, exit: { code: 0 } },
    ]);
    const view = await render({ native });
    const row = await geminiRow();
    expect(row.getAttribute("aria-disabled")).not.toBe("true");
    await act(async () => row.click());
    await settle();
    // The prompt: what it installs and the exact command, and nothing has run yet.
    const prompt = dialog()!;
    expect(prompt).toBeTruthy();
    expect(prompt.querySelector("h2")?.textContent).toBe("Install Gemini CLI?");
    expect(prompt.querySelector("[data-install-command]")?.textContent).toContain("@google/gemini-cli");
    expect(calls).toEqual([]);
    expect(view.started).toEqual([]);

    await act(async () => button(prompt, "Install")!.click());
    await settle();
    await settle();
    const run = calls.find((call) => call.method === "shell.run")!;
    expect(String(run.params.command)).toContain("npm install -g @google/gemini-cli");
    // acpmux looked for it again, the catalog was read again, and only then did the pick land.
    const order = calls.map((call) => call.method);
    expect(order).toContain("harness.health");
    expect(calls.find((call) => call.method === "harness.health")!.params).toMatchObject({
      id: "gemini",
      rescan: true,
    });
    expect(view.refreshed()).toBe(1);
    expect(view.started.length).toBe(1);
    expect(view.started[0]![0]).toBe("gemini");
    expect(view.started[0]![1]).toBe("gemini-3.1-pro-preview");
    expect(dialog()).toBeNull();
  });

  test("a failed install says why, and Try Again runs it again", async () => {
    const { calls, native } = fakeHost([
      { output: "npm ERR! code EACCES\n", next: 1, exit: { code: 243 } },
      { output: "done\n", next: 1, exit: { code: 0 } },
    ]);
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await settle();
    const failure = dialog()!.querySelector('[data-install-status="failed"]');
    expect(failure?.textContent).toBe("Failed: npm ERR! code EACCES");
    expect(view.started).toEqual([]);
    expect(view.refreshed()).toBe(0);
    // The setup page is offered beside Try Again.
    expect(button(dialog()!, "Setup Guide") ?? button(dialog()!, "Setup")).toBeTruthy();

    await act(async () => button(dialog()!, "Try Again")!.click());
    await settle();
    await settle();
    expect(calls.filter((call) => call.method === "shell.run").length).toBe(2);
    expect(view.started.map((args) => args[0])).toEqual(["gemini"]);
    expect(dialog()).toBeNull();
  });

  test("Hide keeps the install running, its progress showing until then, and the pick lands", async () => {
    let finish!: (read: Read) => void;
    const { native } = fakeHost([
      { output: "fetching gemini-cli\n", next: 1 },
      new Promise<Read>((resolve) => {
        finish = resolve;
      }),
    ]);
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    expect(dialog()!.querySelector('[data-install-status="installing"]')?.textContent).toBe("fetching gemini-cli");
    expect(button(dialog()!, "Install")).toBeUndefined();
    await act(async () => button(dialog()!, "Hide")!.click());
    await settle();
    expect(dialog()).toBeNull();
    expect(view.started).toEqual([]);

    await act(async () => finish({ next: 2, exit: { code: 0 } }));
    await settle();
    await settle();
    expect(view.started.map((args) => [args[0], args[1]])).toEqual([["gemini", "gemini-3.1-pro-preview"]]);
  });

  test("Cancel installs nothing and picks nothing", async () => {
    const { calls, native } = fakeHost([]);
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Cancel")!.click());
    await settle();
    expect(dialog()).toBeNull();
    expect(calls).toEqual([]);
    expect(view.started).toEqual([]);
  });

  test("a harness that installs signed out asks for its sign-in, which runs its login, then the pick lands", async () => {
    const { calls, native } = fakeHost([{ output: "added 1 package\n", next: 1, exit: { code: 0 } }], {
      auth: "signedOut",
      login: "gemini",
    });
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await settle();
    // Installed but signed out: no chat yet, the prompt asks for its sign-in.
    expect(dialog()!.querySelector("h2")?.textContent).toBe("Sign in to Gemini CLI");
    expect(view.started).toEqual([]);
    expect(button(dialog()!, "Later")).toBeTruthy();
    await act(async () => button(dialog()!, "Sign In")!.click());
    await settle();
    const login = calls.find((call) => call.method === "tab.open")!;
    expect(login.params).toMatchObject({ kind: "terminal", text: "gemini", run: true, keep: true });
    expect(view.started.map((args) => [args[0], args[1]])).toEqual([["gemini", "gemini-3.1-pro-preview"]]);
    expect(dialog()).toBeNull();
  });

  test("Later after a signed-out install starts nothing", async () => {
    const { calls, native } = fakeHost([{ next: 1, exit: { code: 0 } }], { auth: "signedOut", login: "gemini" });
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await settle();
    await act(async () => button(dialog()!, "Later")!.click());
    await settle();
    expect(dialog()).toBeNull();
    expect(calls.some((call) => call.method === "tab.open")).toBe(false);
    expect(view.started).toEqual([]);
  });

  test("a catalog read that fails after a good install still starts the picked model", async () => {
    const { native } = fakeHost([{ output: "ok\n", next: 1, exit: { code: 0 } }]);
    const view = await render({ native, refreshFails: true });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await settle();
    expect(view.refreshed()).toBe(1);
    expect(dialog()).toBeNull();
    expect(view.started.map((args) => args[0])).toEqual(["gemini"]);
  });

  test("a hidden install outlives the composer that asked, and its pick still lands", async () => {
    let finish!: (read: Read) => void;
    const { calls, native } = fakeHost([
      new Promise<Read>((resolve) => {
        finish = resolve;
      }),
    ]);
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await act(async () => button(dialog()!, "Hide")!.click());
    await view.dropComposer();
    await settle();
    await act(async () => finish({ output: "installed\n", next: 1, exit: { code: 0 } }));
    await settle();
    await settle();
    // Never stopped: the install ran to its end, acpmux looked again, and the pick landed.
    expect(calls.some((call) => call.method === "shell.stop")).toBe(false);
    expect(calls.some((call) => call.method === "harness.health")).toBe(true);
    expect(view.started.map((args) => [args[0], args[1]])).toEqual([["gemini", "gemini-3.1-pro-preview"]]);
  });

  test("another pick made while a hidden install runs wins over the install's pick", async () => {
    let finish!: (read: Read) => void;
    const { native } = fakeHost([
      new Promise<Read>((resolve) => {
        finish = resolve;
      }),
    ]);
    const view = await render({ native });
    await act(async () => (await geminiRow()).click());
    await settle();
    await act(async () => button(dialog()!, "Install")!.click());
    await settle();
    await act(async () => button(dialog()!, "Hide")!.click());
    await settle();
    // Meanwhile the person picks Claude Sonnet on Claude Code's tab.
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-model button")!.click());
    await settle();
    const claudeTab = doc().querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="Claude Code"]')!;
    await act(async () => claudeTab.click());
    await settle();
    const sonnet = [...doc().querySelectorAll<HTMLElement>('.acpmux-cols [role="listbox"] [role="option"]')].find(
      (item) => item.title.endsWith("claude-sonnet-5-5"),
    )!;
    await act(async () => sonnet.click());
    await settle();
    await act(async () => finish({ next: 1, exit: { code: 0 } }));
    await settle();
    await settle();
    expect(view.started.map((args) => args[0])).not.toContain("gemini");
  });

  test("without an installer the rows stay unpickable and Install… opens the Harnesses page", async () => {
    const view = await render();
    const row = await geminiRow();
    expect(row.getAttribute("aria-disabled")).toBe("true");
    await act(async () => row.click());
    await settle();
    expect(dialog()).toBeNull();
    const menu = doc().querySelector('.acpmux-cols [role="listbox"]')!;
    const install = [...menu.querySelectorAll<HTMLElement>('[role="button"]')].find(
      (item) => item.textContent === "Install…",
    )!;
    await act(async () => install.click());
    expect(view.added()).toBe(1);
    expect(dialog()).toBeNull();
  });
});
