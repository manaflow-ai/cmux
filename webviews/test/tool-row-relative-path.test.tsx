// A Read row named the file by its absolute path (dogfood run, hq #1893): "Read
// /Users/you/src/app/docs/guide.md" pushed the file's name off a narrow pane. A row now names a
// file inside the session's folder by its path from there, and keeps a file outside it whole.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const read = (path: string) =>
  ({
    kind: "activity",
    text: "Read",
    tool: { id: path, kind: "read", title: "Read File", status: "completed", locations: [{ path }] },
  }) as never;

test("a tool row names a file in the session's folder by its path from there", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  const { SessionCwdContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SessionCwdContext.Provider value="/Users/you/src/app/">
        <ToolRow item={read("/Users/you/src/app/docs/guide.md")} />
        <ToolRow item={read("/Users/you/notes.md")} />
      </SessionCwdContext.Provider>,
    ),
  );
  const labels = [...host.querySelectorAll(".cv-tool__text")].map((node) => node.textContent);
  expect(labels).toEqual(["Read docs/guide.md", "Read /Users/you/notes.md"]);
});
