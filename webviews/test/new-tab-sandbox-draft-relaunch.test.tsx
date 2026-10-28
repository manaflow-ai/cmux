import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  cmuxAcpmuxBridge?: { receive(value: unknown): void; applyPreview(on: boolean): void };
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

for (const route of ["unsent", "sent", "host receipt"] as const) {
  test(`New Tab ${route} preserves draft ownership through unmount and app remount`, async () => {
    const { createRoot } = await import("react-dom/client");
    const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
    const { noChat } = await import("../src/gallery/fixtures/acpmux");
    let persistedDraft: string | undefined;
    let run: unknown = null;
    let firstState = true;
    let painted = Promise.withResolvers<void>();
    let receiveState: ((value: unknown) => void) | undefined;
    const text = route === "sent" ? "already sent task" : "keep this draft";
    const receipt = { status: "succeeded", reply: "done" };
    const restoredDrafts: (string | undefined)[] = [];
    const calls: Call[] = [];
    paneWindow().webkit = {
      messageHandlers: {
        agentSession: {
          postMessage: async (message: Call) => {
            calls.push(message);
            let value: unknown;
            if (message.method === "ready") {
              restoredDrafts.push(persistedDraft);
              value = {
                protocolVersion: 1,
                transport: "preview",
                newSession: true,
                sandboxState: true,
                draft: persistedDraft,
                newTab: persistedDraft ? undefined : { template: "minimal", cwd: "/tmp/project", lastAgent: "claude" },
              };
            } else if (message.method === "sandbox.state") {
              if (route === "host receipt" && firstState) {
                firstState = false;
                value = await new Promise((resolve) => {
                  receiveState = resolve;
                });
              } else value = run;
            } else if (message.method === "sandbox.run") {
              run = { task: message.params.task, key: message.params.key, reply: { ok: true, value: { receipt } } };
              value = { receipt, runId: "sandbox-1" };
            } else if (message.method === "chat.unsentDraft") persistedDraft = String(message.params.text ?? "");
            else if (message.method === "pane.painted") painted.resolve();
            return { ok: true, value };
          },
        },
      },
    };
    const mount = async () => {
      painted = Promise.withResolvers<void>();
      root = createRoot(host);
      await act(async () => root!.render(<AcpmuxApp />));
      await act(async () => {
        paneWindow().cmuxAcpmuxBridge!.receive(noChat());
        paneWindow().cmuxAcpmuxBridge!.applyPreview(true);
      });
      await act(async () => painted.promise);
    };
    await mount();
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    expect(field).not.toBeNull();
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, text);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    if (route === "sent") {
      await act(async () => host.querySelector<HTMLButtonElement>('[data-kind="computer"] > button')!.click());
      await act(async () => {
        dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Alt", altKey: true }));
      });
      const sandbox = dom.window.document.querySelector<HTMLElement>('[data-mode="sandboxed"]')!;
      expect(sandbox).not.toBeNull();
      await act(async () => sandbox.click());
      await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
      expect(calls.filter((call) => call.method === "sandbox.run")).toHaveLength(1);
    } else if (route === "host receipt") {
      expect(receiveState).toBeDefined();
      run = { task: "earlier task", key: "restored-run", reply: { ok: true, value: { receipt } } };
      await act(async () => receiveState!(run));
      expect(host.querySelector(".nt-field")).toBeNull();
    }
    await act(async () => root!.unmount());
    root = undefined;
    host.replaceChildren();
    await mount();
    const expected = route === "sent" ? "" : text;
    expect(restoredDrafts.at(-1)).toBe(expected);
    expect(persistedDraft).toBe(expected);
  });
}
