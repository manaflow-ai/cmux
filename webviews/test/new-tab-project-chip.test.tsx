// The New Tab field's Return glyph (dogfood run, hq #1893): it looked like the send button, but a
// click on it did nothing; only the Return key sent the prompt. It is the Send button now, and a
// click asks the agent as Return does.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
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
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

const noop = () => {};

/// The New Tab page as Cmd-N opens it: its tab inherited `cwd`, and the chat it starts begins in
/// `startCwd` (the host's start folder) unless the person picks a project.
async function mount(cwd: string, startCwd?: string) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd={cwd}
        {...(startCwd ? { startCwd } : {})}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return host.querySelector<HTMLButtonElement>('.nt-pickers button[aria-label="Project"]')?.textContent ?? "";
}

// Dogfood nxdog92/93 (cx-7fje0, a regression of cx-nn3e): Cmd-N's New Tab composer named its
// project ~, the home folder the tab inherited, while a prompt starts in the host's start folder
// (screenActions onAsk). The chip names that folder, or asks for a project; never the home ~.
test("a Cmd-N New Tab's project chip names the folder its chat starts in, not ~", async () => {
  expect(await mount("/Users/you")).toBe("Choose project");
});

test("a Cmd-N New Tab whose host names a start folder shows that folder", async () => {
  expect(await mount("/Users/you", "/Users/you/src/app")).toBe("app");
});

test("a New Tab that inherited a project folder names it", async () => {
  expect(await mount("/Users/you/src/app")).toBe("app");
});
