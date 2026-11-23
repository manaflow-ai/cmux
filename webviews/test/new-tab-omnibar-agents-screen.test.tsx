// The New Tab field's agent rows in the rendered screen (launchRows.ts): "codex cmux" lists Codex in
// the cmux folders, Return starts Codex there with no prompt, a chat's title finds no row (the field
// starts things; Lucas 2026-11-18), a typed path asks the host for its folder once the field stays still and Tab
// fills the folder in.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
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

async function render(
  calls: unknown[][],
  completeFolder?: (path: string) => Promise<readonly string[]>,
  takeDraft?: () => { text: string; attachments: ComposerAttachment[] },
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        template="default"
        snapshot={noChat(SESSIONS)}
        omnibar={{
          ...EMPTY_OMNIBAR,
          workspaces: [{ id: "ws", name: "cmux-scratch" }],
          tabs: [{ id: "docs", kind: "browser", title: "Omnibar docs", detail: "docs.example.com" }],
          actions: [{ id: "split.right", title: "Split Right", detail: "Panes", keywords: ["panes", "omnibar"] }],
        }}
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
        {...(takeDraft ? { takeDraft } : {})}
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

test.each(["omnibar", "release", "cmux", "notes"])('a chat\'s title or folder finds no row for "%s"', async (query) => {
  await render([]);
  await type(query);
  expect(options().length).toBeGreaterThan(0);
  expect(options().map((row) => row.dataset.type)).not.toContain("chat");
  expect(options().map(label)).not.toEqual(expect.arrayContaining(["Omnibar ranking"]));
  expect(options().map(label)).not.toEqual(expect.arrayContaining(["Release notes"]));
});

test("commands omit their group and pages their host; the prompt's own Ask has no row", async () => {
  await render([]);
  await type("omnibar");
  const row = (type: string) => options().find((option) => option.dataset.type === type)!;
  expect(row("action").querySelector(".nt-row-title")?.textContent).toBe("Split Right");
  expect(row("action").querySelector(".nt-row-detail")).toBeNull();
  // Return asks the agent and model the chip names, with no row of its own (David Beyer 2026-11-20).
  expect(options().some((option) => option.dataset.type === "ask")).toBe(false);
  expect(row("tab").querySelector(".nt-row-detail")?.textContent).toBe("docs.example.com");
});

test("commands still match their group keyword without displaying it", async () => {
  await render([]);
  await type("panes");
  const command = options().find((row) => row.dataset.type === "action")!;
  expect(label(command)).toBe("Split Right");
  expect(command.querySelector(".nt-row-detail")).toBeNull();
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

const selected = () => options().findIndex((row) => row.getAttribute("aria-selected") === "true");

test("Tab fills the top row's folder once; on a row Tab stepped to, the next Tab steps on", async () => {
  await render([], async () => ["games", "gallery"]);
  const { handle, editable } = await type("~/fun/ga");
  await until(() => options().map(label).includes("Claude Code in ~/fun/games"));
  const starts = options()
    .map((row, index) => (label(row).includes(" in ~/fun/") ? index : -1))
    .filter((index) => index >= 0);
  expect(starts.length).toBeGreaterThan(1);
  // Step to the first start row, then Tab again: the selection moves on, the text stays.
  while (selected() < starts[0]!) await key(editable, "Tab");
  const text = handle.agentText(handle.value());
  await key(editable, "Tab");
  expect(selected()).toBe(starts[0]! + 1);
  expect(handle.agentText(handle.value())).toBe(text);
});

test("a folder listed once is read again when the path comes back, so a new folder shows", async () => {
  let folders = ["cmux", "games"];
  const asked: string[] = [];
  await render([], async (path) => {
    asked.push(path);
    return folders;
  });
  const { handle } = await type("codex ~/fun/ga");
  await until(() => options().map(label).includes("Codex in ~/fun/games"));
  folders = ["cmux", "games", "gallery"];
  const retype = (text: string) =>
    act(async () => {
      handle.selectAll();
      handle.type(text);
    });
  await retype("codex ~/");
  await until(() => asked.includes("/Users/me"));
  await retype("codex ~/fun/ga");
  await until(() => options().map(label).includes("Codex in ~/fun/gallery"));
});

test("a press on a start row starts an empty chat there; the staged files stay for the prompt", async () => {
  const calls: unknown[][] = [];
  const file: ComposerAttachment = {
    id: "f1",
    kind: "image",
    name: "shot.png",
    mimeType: "image/png",
    size: 3,
    data: "AQID",
  };
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ attachmentView: "strip" });
  await render(calls, undefined, () => ({ text: "", attachments: [file] }));
  await type("codex cmux");
  await until(() => host.querySelectorAll(".acpmux-attachments .acpmux-attachment").length === 1);
  const start = options().find((row) => label(row) === "Codex in ~/fun/cmux")!;
  await act(async () => start.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(calls).toHaveLength(1);
  expect(calls[0]!.slice(0, 4)).toEqual(["ask", "codex", "", "/Users/me/fun/cmux"]);
  const sent = calls[0]![6] as ComposerAttachment[] | undefined;
  expect(sent ?? []).toEqual([]);
  setComposerSettings({ attachmentView: "inline" });
});
