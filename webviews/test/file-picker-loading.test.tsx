import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { FileSearchSource } from "../src/agent-session/acpmux/fileSearchModel";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "https://cmux.test/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
});
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});
afterAll(() => {
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});
const placeholders = () => host.querySelectorAll("[data-file-search-placeholder]");
const results = [{ path: "src/example.ts", matches: [] }];

async function enterQuery(value: string) {
  const field = host.querySelector("input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

test("file search keeps rows while the first result arrives and cached rows during refresh", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FileSearch } = await import("../src/agent-session/acpmux/FileSearch");
  let answer!: (value: unknown) => void;
  let requested!: () => void;
  let started = new Promise<void>((resolve) => {
    requested = resolve;
  });
  const search: FileSearchSource = () =>
    new Promise((resolve) => {
      answer = resolve;
      requested();
    });
  const picked: string[] = [];
  await act(async () => {
    root = createRoot(host);
    root.render(<FileSearch search={search} debounceMs={0} onPick={(path) => picked.push(path)} onClose={() => {}} />);
  });
  expect(placeholders()).toHaveLength(0);
  await enterQuery("example");
  await act(async () => started);
  expect(placeholders()).toHaveLength(3);
  expect(host.querySelectorAll('[role="option"]')).toHaveLength(0);
  expect(host.querySelector('[aria-busy="true"]')).not.toBeNull();
  await act(async () => answer({ root: "/project", results }));
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelector('[role="option"]')?.textContent).toContain("example.ts");
  started = new Promise<void>((resolve) => {
    requested = resolve;
  });
  await enterQuery("example-new");
  await act(async () => started);
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelectorAll('[role="option"]')).toHaveLength(1);
  await act(async () => {
    host
      .querySelector("input")!
      .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(picked).toEqual(["src/example.ts"]);
  await act(async () => answer({ root: "/project", results: [] }));
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelector("output")?.textContent).toBeTruthy();
});

test("mention loading rows are decorative and yield to results, empty and failure states", async () => {
  const { createRoot } = await import("react-dom/client");
  const { MentionMenu } = await import("../src/agent-session/acpmux/MentionMenu");
  const { mentionItems } = await import("../src/agent-session/acpmux/mentionItems");
  const render = async (
    state: Parameters<typeof MentionMenu>[0]["state"],
    items: Parameters<typeof MentionMenu>[0]["items"] = [],
  ) => {
    await act(async () => {
      root ??= createRoot(host);
      root.render(<MentionMenu state={state} items={items} active={-1} onHover={() => {}} onPick={() => {}} />);
    });
  };
  await render({ kind: "searching", results: [] });
  expect(placeholders()).toHaveLength(3);
  expect(host.querySelectorAll('button, [role="option"], [tabindex]')).toHaveLength(0);
  expect([...placeholders()].every((row) => row.getAttribute("aria-hidden") === "true")).toBe(true);
  const items = mentionItems({ query: "example", files: results, sessions: [] });
  await render({ kind: "searching", results }, items);
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelectorAll('[role="option"]')).toHaveLength(1);
  await render({ kind: "done", results: [] });
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelector("output")?.textContent).toBeTruthy();
  await render({ kind: "failed" });
  expect(placeholders()).toHaveLength(0);
  expect(host.querySelector("output")?.textContent).toBeTruthy();
});
