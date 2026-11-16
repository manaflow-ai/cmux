// A New Tab whose extension (`tabs.newTabApp`, cmux.newtab/1) hangs or throws keeps cmux's own
// composer: it draws from the first frame, takes typing and sends, before, while and after the
// extension's slot gives up. Leo, 2026-11-16, of an extension that replaced the page and then took
// the pane down with it: "it's also unusable, and it also fucks up the app, it just doesn't do
// anything". The extension only ever has its slot over the composer (newtab/NewTabAppSlot.tsx).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";
import { until } from "./support/until";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const added: string[] = [];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    // The composer's footer row fits its chips to its width (composerRowFit.ts) on every New Tab.
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  for (const key of added) delete scope[key];
  await teardownDom(saved, { scope });
});

const noop = () => {};

/// The page host as a hung extension leaves it: `mount` never answers, or the scene stream says the
/// render threw. Every other call answers at once.
function extensionHost(mode: "hang" | "throws"): PageClient & { mounts: number } {
  let scene: ((event: unknown, seq: number) => void) | undefined;
  const client = {
    mounts: 0,
    async call<R>(op: string): Promise<R> {
      if (op !== "cmux.apps.panels.mount") return {} as R;
      client.mounts += 1;
      if (mode === "hang") return new Promise<R>(noop);
      setTimeout(() => scene?.({ mount_id: "m1", status: "failed", reason: "TypeError: not a function" }, 1), 0);
      return { mount_id: "m1" } as R;
    },
    async subscribe<E>(_stream: string, callback: (event: E, seq: number) => void) {
      scene = callback as (event: unknown, seq: number) => void;
      return noop;
    },
    handle: () => noop,
  };
  return client;
}

for (const mode of ["hang", "throws"] as const)
  test(`an extension that ${mode === "hang" ? "never answers" : "throws"} leaves the composer typing and sending`, async () => {
    window.localStorage.clear();
    const { createRoot } = await import("react-dom/client");
    const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
    const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
    const { NewTabAppSlot } = await import("../src/agent-session/acpmux/newtab/NewTabAppSlot");
    const extension = extensionHost(mode);
    const gone: string[] = [];
    const asks: unknown[][] = [];
    const root = createRoot(host);
    try {
      await act(async () =>
        root.render(
          <QueryClientProvider client={new QueryClient()}>
            <NewTabScreen
              template="minimal"
              snapshot={noChat()}
              lastAgent="claude"
              cwd="/Users/you/src/app"
              above={
                <NewTabAppSlot
                  app="local/clocktab"
                  client={extension}
                  deadlineMs={40}
                  onUnavailable={(reason) => gone.push(reason)}
                />
              }
              onAsk={(...args) => void asks.push(args)}
              onOpen={noop}
              onSearch={noop}
              onShell={noop}
              onJump={noop}
              onOpenSession={noop}
              onShowAll={noop}
            />
          </QueryClientProvider>,
        ),
      );
      expect(extension.mounts).toBe(1);
      // The composer is the page's from the first frame, beside the extension's slot, never under it.
      const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
      expect(field).not.toBeNull();
      expect(host.querySelector(".nt-above-room .nt-app-slot")).not.toBeNull();
      expect(host.querySelector(".nt-app-slot .nt-field")).toBeNull();
      for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
        await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      const handle = field.acpmuxMarkdownField!;
      // Typing while the extension is still out (hung, or about to throw).
      await act(async () => {
        handle.focus();
        handle.type("fix the flaky");
      });
      // The slot gives up (its deadline, or the throw); nothing else on the page changes.
      await until(
        () => gone.length > 0,
        () => act(async () => new Promise((resolve) => setTimeout(resolve, 0))),
      );
      expect(gone).toHaveLength(1);
      if (mode === "throws") expect(gone[0]).toContain("TypeError");
      // The room over the composer stays: the composer does not move when the slot empties.
      expect(host.querySelector(".nt-above-room")).not.toBeNull();
      expect(host.querySelector(".nt-app-slot")?.hasAttribute("data-gone")).toBe(true);
      expect(host.querySelector(".nt-field")).toBe(field);
      // The draft typed while the extension was out is still there, in the same field.
      expect(handle.value()).toBe("fix the flaky");
      const full = "fix the flaky upload test";
      await act(async () => handle.writeText(full, full.length, full.length));
      expect(handle.value()).toBe("fix the flaky upload test");
      const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
      await act(async () =>
        editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
      );
      expect(asks.length).toBe(1);
      expect(asks[0]![1]).toBe("fix the flaky upload test");
    } finally {
      await act(async () => root.unmount());
    }
  });
