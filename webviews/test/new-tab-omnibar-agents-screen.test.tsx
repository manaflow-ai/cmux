// The New Tab field's agent rows in the rendered screen (launchRows.ts): "codex cmux" lists Codex in
// the cmux folders under a header-free lead, Return starts Codex there with no prompt, a chat row
// opens its chat, a typed path asks the host for its folder once the field stays still and Tab
// fills the folder in, and the sections carry their headers.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
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
  "MutationObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
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
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const noop = () => {};
const SESSIONS = [
  { sessionId: "s1", displayTitle: "Omnibar ranking", harness: "claude", cwd: "/Users/me/fun/cmux", activityAt: 5 },
  { sessionId: "s2", displayTitle: "Release notes", harness: "codex", cwd: "/Users/me/notes", activityAt: 4 },
] as AcpmuxSessionEntry[];

async function render(calls: unknown[][], completeFolder?: (path: string) => Promise<readonly string[]>) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        template="default"
        snapshot={noChat(SESSIONS)}
        omnibar={{ ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "cmux-scratch" }] }}
        home="/Users/me"
        lastAgent="claude"
        projects={[
          { cwd: "/Users/me/fun/cmux", label: "cmux" },
          { cwd: "/Users/me/code/site", label: "site" },
        ]}
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={(id) => calls.push(["session", id])}
        onShowAll={noop}
        {...(completeFolder ? { completeFolder } : {})}
      />,
    ),
  );
}

async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  return { handle, editable: field.querySelector<HTMLElement>("[contenteditable]")! };
}

const options = () => [...window.document.querySelectorAll<HTMLElement>('.nt-rows [role="option"]')];
const label = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";
const headers = () => [...window.document.querySelectorAll<HTMLElement>(".nt-section")].map((h) => h.textContent);
const key = (field: Element, name: string) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });
/// Turns of the event loop until `done` holds (the field's settle timer and the host's answer).
async function until(done: () => boolean) {
  for (let turn = 0; turn < 500 && !done(); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(done()).toBe(true);
}

test('"codex cmux" leads with Codex in the cmux folder, and Return starts it there with no prompt', async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const { editable } = await type("codex cmux");
  expect(label(options()[0]!)).toBe("Codex in ~/fun/cmux");
  await key(editable, "Enter");
  expect(calls).toHaveLength(1);
  expect(calls[0]!.slice(0, 4)).toEqual(["ask", "codex", "", "/Users/me/fun/cmux"]);
});

test("a chat's title finds it under the Chats header, and a press opens it", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  await type("omnibar");
  expect(headers()).toContain("Chats");
  const chat = options().find((row) => label(row) === "Omnibar ranking")!;
  expect(chat).toBeDefined();
  await act(async () => chat.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(calls).toEqual([["session", "s1"]]);
});

test("a typed path lists its folder's subfolders once the host answers, and Tab fills the folder", async () => {
  const asked: string[] = [];
  await render([], async (path) => {
    asked.push(path);
    return ["cmux", "games"];
  });
  const { handle, editable } = await type("codex ~/fun/ga");
  // Before the field settles nothing is asked: a keystroke never waits on the disk.
  expect(asked).toEqual([]);
  await until(() => options().map(label).includes("Codex in ~/fun/games"));
  expect(asked).toEqual(["/Users/me/fun"]);
  await key(editable, "Tab");
  // The field holds Markdown (`\~`); the page acts on its text.
  expect(handle.agentText(handle.value())).toBe("codex ~/fun/games/");
});
