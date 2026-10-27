// The classic New Tab must use the same deferred picker path as the other templates.
// Mount the real app boundary so choosing the active-chat fallback cannot pass unnoticed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

type Call = { method: string; params: Record<string, unknown> };
type PaneWindow = Window & {
  webkit?: unknown;
  cmuxAcpmuxRegistry?: { register(kind: string, renderer: unknown): void };
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  cmuxAcpmuxBridge?: { receive(value: unknown): void };
};
const paneWindow = () => dom.window as unknown as PaneWindow;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  delete paneWindow().cmuxAcpmuxRegistry;
  delete paneWindow().cmuxAcpmuxActions;
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

async function mount(
  options: {
    noSummary?: boolean;
    noOptions?: boolean;
    plugin?: React.ComponentType<{ snapshot: AcpmuxSnapshot; cwd?: string }>;
  } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  const { noChat } = await import("../src/gallery/fixtures/acpmux");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { resetModelCatalogForTests } = await import("../src/agent-session/acpmux/modelCatalogHost");
  resetModelCatalogForTests();
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    // A live model probe can report only id/name; the bundled catalog supplies its capabilities.
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  }));
  const snapshot = noChat([], {
    catalog,
    ...(!options.noSummary
      ? {
          switching: { harness: "claude", name: "Claude Code", phase: "deferred" },
          summary: {
            sessionId: "",
            harness: "claude",
            model: "claude-opus-5-5",
            ...(!options.noOptions
              ? {
                  configOptions: [
                    {
                      id: "effort",
                      name: "Effort",
                      category: "thought_level",
                      currentValue: "medium",
                      options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
                    },
                    {
                      id: "fast-mode",
                      name: "Fast mode",
                      currentValue: "off",
                      options: [
                        { value: "off", name: "Off" },
                        { value: "on", name: "On" },
                      ],
                    },
                  ],
                }
              : {}),
          },
        }
      : {}),
  } as Partial<AcpmuxSnapshot>);
  const calls: Call[] = [];
  paneWindow().webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: Call) => {
          calls.push(message);
          return Promise.resolve({
            ok: true,
            value:
              message.method === "ready"
                ? {
                    protocolVersion: 1,
                    transport: "preview",
                    newSession: true,
                    machineName: "Mac",
                    cwd: "/tmp/classic-project",
                    newTab: {
                      template: "classic",
                      cwd: "/tmp/classic-project",
                      lastAgent: "claude",
                      projects: ["/tmp/classic-project", "/tmp/other-project"],
                    },
                  }
                : undefined,
          });
        },
      },
    },
  };
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  if (options.plugin) await act(async () => paneWindow().cmuxAcpmuxRegistry!.register("composerChips", options.plugin));
  await act(async () => paneWindow().cmuxAcpmuxBridge!.receive(snapshot));
  expect(host.querySelector(".acpmux-newtab-field")).not.toBeNull();
  // Direct hosts install these actions after the handshake. Recording them checks ordering at
  // the page boundary without starting a real daemon session.
  paneWindow().cmuxAcpmuxActions = Object.fromEntries(
    ["chat.new", "chat.model", "chat.mode", "chat.effort", "chat.send"].map((method) => [
      method,
      async (params: Record<string, unknown>) => void calls.push({ method, params }),
    ]),
  );
  return {
    calls,
    chatCalls: () => calls.filter((call) => call.method.startsWith("chat.")),
    report: async (harness: string, model: string) =>
      act(async () =>
        paneWindow().cmuxAcpmuxBridge!.receive({
          ...snapshot,
          summary: { ...snapshot.summary, harness, model },
          switching: { harness, name: harness, phase: "deferred" },
        }),
      ),
  };
}

/** The menu open last (a submenu opens over its menu): the newest element whose role is menu. */
const popup = () => {
  const menu = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menu"]')].at(-1);
  expect(menu, "an open menu").toBeDefined();
  return menu!;
};
/** That menu's own rows a click can pick: not a nested menu's, not a disabled one. */
const items = () =>
  [...popup().querySelectorAll<HTMLElement>('[role^="menuitem"]')].filter(
    (row) =>
      row.closest('[role="menu"]') === popup() &&
      row.getAttribute("aria-disabled") !== "true" &&
      !row.hasAttribute("disabled"),
  );
const label = (item: Element) => item.querySelector(".acpmux-menu-label")?.textContent ?? "";
/** Clicks the one enabled row named `name`; two rows of that name fail rather than pick either. */
async function pick(name: string) {
  const matches = items().filter((entry) => label(entry) === name);
  expect(matches.length, `one enabled menu row named ${name}`).toBe(1);
  await act(async () => matches[0]!.click());
}
async function open() {
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
}
const deferred = { harness: "claude", cwd: "/tmp/classic-project", deferred: true };

test("a classic New Tab starts its deferred chat before changing model", async () => {
  const { chatCalls } = await mount();
  await open();
  await pick("Sonnet 5.5");
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: deferred },
    { method: "chat.model", params: { modelId: "claude-sonnet-5-5" } },
  ]);
});

test("a classic New Tab holds its effort and Fast mode picks on a deferred chat", async () => {
  const { chatCalls } = await mount();
  await open();
  await pick("Effort");
  await pick("High");
  await open();
  await pick("Fast mode");
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: deferred },
    { method: "chat.effort", params: { configId: "effort", value: "high" } },
    { method: "chat.new", params: deferred },
    { method: "chat.effort", params: { configId: "fast-mode", value: "on" } },
  ]);
});

test("a fresh New Tab keeps catalog Fast mode in the model menu before a session reports options", async () => {
  const { chatCalls } = await mount({ noOptions: true });
  await open();
  const fast = items().find((entry) => label(entry) === "Fast mode");
  expect(fast, "Fast mode row from the catalog").toBeDefined();
  await act(async () => fast!.click());
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: deferred },
    { method: "chat.effort", params: { configId: "fast-mode", value: "on" } },
  ]);
});

test("a classic New Tab starts another harness and its model behind the page", async () => {
  const { chatCalls } = await mount();
  await open();
  await act(async () => popup().querySelector<HTMLButtonElement>('[aria-label="Codex"]')!.click());
  await pick("GPT-6 Astra");
  expect(chatCalls()).toEqual([
    {
      method: "chat.new",
      params: { harness: "codex", model: "gpt-6-astra", cwd: "/tmp/classic-project", deferred: true },
    },
  ]);
});

test("a classic New Tab seeds its default harness before its first model pick", async () => {
  const { chatCalls } = await mount({ noSummary: true });
  await open();
  await pick("Sonnet 5.5");
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: deferred },
    { method: "chat.model", params: { modelId: "claude-sonnet-5-5" } },
  ]);
});

test("a classic New Tab preserves the registry's composer chip override", async () => {
  await mount({ plugin: () => <span data-plugin-chips>Custom controls</span> });
  expect(host.querySelector("[data-plugin-chips]")?.textContent).toBe("Custom controls");
  expect(host.querySelector('[data-menu="Model"]')).toBeNull();
});

test("classic Return keeps the selected harness and model when opening its deferred chat", async () => {
  const { chatCalls, report } = await mount();
  await report("codex", "gpt-6-astra");
  const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, "fix this test");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: { harness: "codex", model: "gpt-6-astra", cwd: "/tmp/classic-project" } },
    { method: "chat.send", params: { text: "fix this test" } },
  ]);
});

test("classic Return sends its prompt in the same turn as the chat start, as the New Tab screen does", async () => {
  const { chatCalls } = await mount();
  // A switch held on the folder's trust question has not resolved `chat.new`: the prompt must
  // already be with it, never waiting for the start to settle.
  const actions = paneWindow().cmuxAcpmuxActions!;
  const record = actions["chat.new"]!;
  actions["chat.new"] = (params) => {
    void record(params);
    return new Promise(() => undefined);
  };
  const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, "hello");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(chatCalls().map((call) => call.method)).toEqual(["chat.new", "chat.send"]);
  expect(chatCalls()[1]!.params).toEqual({ text: "hello" });
});

test("classic composer plugins receive the page's selected folder", async () => {
  await mount({ plugin: ({ cwd }) => <span data-plugin-folder>{cwd}</span> });
  expect(host.querySelector("[data-plugin-folder]")?.textContent).toBe("/tmp/classic-project");
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  const other = dom.window.document.querySelector<HTMLElement>(
    '.acpmux-project-menu [role="option"][aria-label$="/tmp/other-project"]',
  );
  expect(other).not.toBeNull();
  await act(async () => other!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(host.querySelector("[data-plugin-folder]")?.textContent).toBe("/tmp/other-project");
});

test("a classic model pick starts in the project selected on the page", async () => {
  const { chatCalls } = await mount();
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  const other = dom.window.document.querySelector<HTMLElement>(
    '.acpmux-project-menu [role="option"][aria-label$="/tmp/other-project"]',
  );
  expect(other).not.toBeNull();
  await act(async () => other!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  await open();
  await pick("Sonnet 5.5");
  expect(chatCalls()).toEqual([
    { method: "chat.new", params: { ...deferred, cwd: "/tmp/other-project" } },
    { method: "chat.model", params: { modelId: "claude-sonnet-5-5" } },
  ]);
});
