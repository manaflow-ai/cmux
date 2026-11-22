// A terminal or browser tab from the classic New Tab page (Terminal | Browser | Agent) waited for
// acpmux's handshake like a chat, and a refused open vanished: `void callNative("tab.open")` had no
// catch, so Return after a slow handshake left the page as it was with no word why (cx-hnpxh).
// A terminal or browser tab is the host's to make, so it opens at once; only a chat waits for the
// handshake. A refused open says so under the field and keeps what was typed.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { classicField } from "./support/classicNewTabField";
import { until } from "./support/until";
import { teardownDom } from "./support/domTeardown";

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
  "getSelection",
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

async function renderPage(
  onSubmit: (kind: "terminal" | "browser" | "agent", text: string, cwd?: string) => unknown,
  initialKind: "terminal" | "browser" | "agent" = "terminal",
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabPage
        snapshot={noChat()}
        initialKind={initialKind}
        cwd="/Users/you/src/app"
        onSubmit={onSubmit as never}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  // The page's field is the chat composer's prompt editor (MarkdownField).
  const field = await classicField(host);
  const type = field.type;
  const submit = async () => {
    await act(async () => {
      host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
    });
    // The refusal settles after the submit's turn.
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  };
  return { root, field, type, submit };
}

test("the classic New Tab agent field follows the opt-in spell checking setting", async () => {
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ spellChecking: false });
  const { root, field } = await renderPage(noop, "agent");
  try {
    expect(field.editor.getAttribute("spellcheck")).toBe("false");
    await act(async () => setComposerSettings({ spellChecking: true }));
    expect(field.editor.getAttribute("spellcheck")).toBe("true");
  } finally {
    await act(async () => setComposerSettings({ spellChecking: false }));
    await act(async () => root.unmount());
  }
});

test("a terminal from the New Tab page opens before the handshake, and a refusal says so", async () => {
  const { newTabPageSubmit } = await import("../src/agent-session/acpmux/newtab/pageSubmit");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  const waiting: (() => void)[] = [];
  const onSubmit = newTabPageSubmit({
    callNative: async (method, params) => {
      calls.push({ method, ...(params ? { params } : {}) });
      throw new Error("transport.gesture_required");
    },
    // acpmux has not answered: nothing that waits for it runs.
    whenHandshaken: (run) => void waiting.push(run),
    startChat: (text) => void calls.push({ method: "chat", params: { text } }),
  });
  const { root, field, type, submit } = await renderPage(onSubmit);
  try {
    expect(host.querySelector('[role="alert"]')).toBeNull();
    await type("echo held");
    expect(host.querySelector('[role="listbox"]')).not.toBeNull();
    await submit();
    expect(calls).toEqual([
      { method: "tab.open", params: { kind: "terminal", text: "echo held", cwd: "/Users/you/src/app" } },
    ]);
    expect(waiting).toHaveLength(0);
    // Plain words for what did not happen, Retry, and the host's own words under Details (2026-11-08).
    const alert = host.querySelector('[role="alert"]')!;
    expect(alert.querySelector(".acpmux-newtab-failed-message")?.textContent).toBe("The terminal didn't open.");
    expect(alert.querySelector("details")?.textContent).toContain("transport.gesture_required");
    expect(field.value()).toBe("echo held");
    const retry = [...alert.querySelectorAll("button")].find((b) => b.textContent === "Retry")!;
    expect(retry).toBeDefined();
    await act(async () => retry.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
    await until(
      () => calls.length >= 2,
      () => act(async () => {}),
    );
    expect(calls).toHaveLength(2);
    expect(calls[1]).toEqual(calls[0]!);
    // The suggestions that float under the field close, so they never cover the note.
    expect(host.querySelector('[role="listbox"]')).toBeNull();
    // Editing the field clears the note.
    await type("echo held again");
    expect(host.querySelector('[role="alert"]')).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a refused browser tab says the page did not open; an empty refusal has no Details", async () => {
  const { root, type, submit } = await renderPage(() => Promise.reject(new Error("")), "browser");
  try {
    await type("example.com");
    await submit();
    const alert = host.querySelector('[role="alert"]')!;
    expect(alert.querySelector(".acpmux-newtab-failed-message")?.textContent).toBe("The page didn't open.");
    expect(alert.querySelector("details")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat from the New Tab page still waits for the handshake", async () => {
  const { newTabPageSubmit } = await import("../src/agent-session/acpmux/newtab/pageSubmit");
  const calls: string[] = [];
  const waiting: (() => void)[] = [];
  const onSubmit = newTabPageSubmit({
    callNative: async (method) => void calls.push(method),
    whenHandshaken: (run) => void waiting.push(run),
    startChat: (text) => void calls.push(`chat:${text}`),
  });
  expect(onSubmit("agent", "fix the test")).toBeUndefined();
  expect(calls).toEqual([]);
  for (const run of waiting) run();
  expect(calls).toEqual(["chat:fix the test"]);
  // A browser tab opens at once too.
  await onSubmit("browser", "example.com");
  expect(calls).toEqual(["chat:fix the test", "tab.open"]);
});

test("a classic New Tab image reaches the first chat prompt", async () => {
  const { newTabPageSubmit } = await import("../src/agent-session/acpmux/newtab/pageSubmit");
  const image: ComposerAttachment = {
    id: "image-1",
    kind: "image",
    name: "Screenshot.png",
    mimeType: "image/png",
    size: 4,
    data: "iVBO",
  };
  let received: unknown[] | undefined;
  const waiting: (() => void)[] = [];
  const onSubmit = newTabPageSubmit({
    callNative: async () => undefined,
    whenHandshaken: (run) => void waiting.push(run),
    startChat: (...args) => {
      received = args;
    },
  });
  expect(onSubmit("agent", "what is this", "/Users/you/src/app", [image])).toBeUndefined();
  expect(received).toBeUndefined();
  waiting.forEach((run) => run());
  expect(received).toEqual(["what is this", "/Users/you/src/app", [image]]);
});
