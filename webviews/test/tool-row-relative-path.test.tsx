// A Read row named the file by its absolute path (dogfood run, hq #1893): "Read
// /Users/you/src/app/docs/guide.md" pushed the file's name off a narrow pane. A row now names a
// file inside the session's folder by its path from there, and keeps a file outside it whole. A Read
// row now names the file alone (ReadLabel.tsx); edit rows keep the path from the session's folder.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const tool = (kind: string, path: string) =>
  ({
    kind: "activity",
    text: kind === "read" ? "Read" : "Edit",
    tool: { id: path, kind, title: kind === "read" ? "Read File" : "Edit", status: "completed", locations: [{ path }] },
  }) as never;

async function render(kind: string) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  const { SessionCwdContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SessionCwdContext.Provider value="/Users/you/src/app/">
        <ToolRow item={tool(kind, "/Users/you/src/app/docs/guide.md")} />
        <ToolRow item={tool(kind, "/Users/you/notes.md")} />
      </SessionCwdContext.Provider>,
    ),
  );
  return [...host.querySelectorAll(".cv-tool__text")].map((node) => node.textContent);
}

test("a tool row names a file in the session's folder by its path from there", async () => {
  expect(await render("edit")).toEqual(["Edit docs/guide.md", "Edit /Users/you/notes.md"]);
});

// Since the 2026-11-14 change a Read row names its file by its name alone, the full path on hover.
test("a Read row names its file by its name, with its full path as the title", async () => {
  expect(await render("read")).toEqual(["Read guide.md", "Read notes.md"]);
  const titles = [...host.querySelectorAll(".cv-tool__file")].map((node) => node.getAttribute("title"));
  expect(titles).toEqual(["/Users/you/src/app/docs/guide.md", "/Users/you/notes.md"]);
});
