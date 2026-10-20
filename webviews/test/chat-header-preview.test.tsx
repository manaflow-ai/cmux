// The chat header's Preview button (cx-00n1, Claude Code desktop's preview toggle): it shows when the
// chat's last turn started or mentioned a local web page, hidden (not disabled, cx-qom0) otherwise, runs
// with that page and its mode, and lights while the App reports its page open; an open page keeps the
// button, so the same spot closes it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("Preview shows with the chat's local page or its open preview, and lights while it is open", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  // Preview shown as a button (it is in the chat menu by default), and nothing open yet (other files in
  // this run share the page's modules).
  configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "changes", "preview", "newTab"] });
  applyHostEvent({ kind: "headerState", value: { lit: [] } });
  const runs: string[] = [];
  root = createRoot(host);
  const render = (previewUrl: string | undefined) =>
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={() => {}}
          previewUrl={previewUrl}
          onPreview={(url, mode) => runs.push(`${mode} ${url}`)}
          summary={null}
          menu={() => []}
        />,
      ),
    );
  const preview = () => host.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Preview"]');
  render(undefined);
  expect(preview()).toBeNull();
  render("http://localhost:5173/");
  expect(preview()?.getAttribute("title")).toBe("Preview localhost:5173");
  expect(preview()?.getAttribute("aria-pressed")).toBe("false");
  act(() => preview()!.click());
  expect(runs).toEqual(["toggle http://localhost:5173/"]);
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.preview] } }));
  expect(preview()?.getAttribute("aria-pressed")).toBe("true");
  // A later turn named no page, but the preview is still open: the button stays to close it.
  render(undefined);
  expect(preview()?.getAttribute("aria-pressed")).toBe("true");
  act(() => preview()!.click());
  expect(runs).toEqual(["toggle http://localhost:5173/", "toggle undefined"]);
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [] } }));
  expect(preview()).toBeNull();
});
