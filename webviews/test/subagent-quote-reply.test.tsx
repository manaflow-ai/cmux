// Quote in Reply in a subagent's pane (App.tsx `quoteReply`): the pane shows the subagent's own
// composer (SubagentComposer.tsx), not the chat's, so the quote goes into the subagent's prompt at
// once, never held for the chat's composer to take when it mounts again. Follows Leo, 2026-11-06,
// on a subagent: "I should be able to, like, copy the stuff that it did."
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
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
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "MouseEvent",
  "Event",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    MouseEvent: window.MouseEvent,
    Event: window.Event,
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

test("a quote goes into the subagent composer's prompt through its quote handle", async () => {
  const { createRoot } = await import("react-dom/client");
  const { SubagentComposer } = await import("../src/agent-session/acpmux/subagents/SubagentComposer");
  const quoteRef: { current: { quoteReply(markdown: string): void } | null } = { current: null };
  root = createRoot(host);
  await act(async () =>
    root!.render(<SubagentComposer subagent="Helper" chat="Chat" draftKey="chat\u001fhelper" quoteRef={quoteRef} />),
  );
  await until(() => quoteRef.current !== null && !!host.querySelector(".acpmux-md"));
  await act(async () => quoteRef.current!.quoteReply("> Neither blocks the five problems."));
  await until(() => (host.querySelector(".acpmux-md")?.textContent ?? "").includes("Neither blocks"));
  expect(host.querySelector(".acpmux-md blockquote")?.textContent).toContain("Neither blocks the five problems.");
  act(() => root?.unmount());
  root = undefined;
  expect(quoteRef.current).toBeNull();
});

test("a quote taken before the editor is ready survives the pane closing and comes back on reopen", async () => {
  const { createRoot } = await import("react-dom/client");
  const { SubagentComposer } = await import("../src/agent-session/acpmux/subagents/SubagentComposer");
  const { subagentDraft } = await import("../src/agent-session/acpmux/subagents/subagentDrafts");
  const key = "chat\u001fearly";
  const quoteRef: { current: { quoteReply(markdown: string): void } | null } = { current: null };
  root = createRoot(host);
  // The first render's effects run, so the handle is set, but the editor is still being made.
  act(() => root!.render(<SubagentComposer subagent="Helper" chat="Chat" draftKey={key} quoteRef={quoteRef} />));
  expect(quoteRef.current).not.toBeNull();
  act(() => quoteRef.current!.quoteReply("> Early quote."));
  act(() => root!.unmount());
  root = undefined;
  expect(subagentDraft(key).text).toContain("> Early quote.");
  root = createRoot(host);
  await act(async () => root!.render(<SubagentComposer subagent="Helper" chat="Chat" draftKey={key} />));
  await until(() => (host.querySelector(".acpmux-md")?.textContent ?? "").includes("Early quote."));
  expect(host.querySelector(".acpmux-md")?.textContent).toContain("Early quote.");
});
