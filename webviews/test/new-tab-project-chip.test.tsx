// The New Tab composer's project (its location row's folder) names the folder a prompt starts in (screenActions onAsk):
// a real pick, else the host's start folder; never the home ~ a Cmd-N tab inherits (cx-7fje0).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

async function mount(cwd: string, startCwd?: string, startPending = false) {
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
        {...(startPending ? { startPending: true } : {})}
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
  // The folder control of the card's location row (the agent composer's, ComposerContext).
  return (
    host.querySelector<HTMLButtonElement>('.acpmux-composer-context button[aria-label="Folder"]')?.textContent ?? ""
  );
}

// Dogfood nxdog92/93 (cx-7fje0, a regression of cx-nn3e): Cmd-N's New Tab composer named its
// project ~, the home folder the tab inherited, while a prompt starts in the host's start folder
// (screenActions onAsk). The chip names that folder, or asks for a project; never the home ~.
test("a Cmd-N New Tab's project chip names the folder its chat starts in, not ~", async () => {
  expect(await mount("/Users/you")).toBe("Choose folder");
});

test("a Cmd-N New Tab whose host names a start folder shows that folder", async () => {
  expect(await mount("/Users/you", "/Users/you/src/app")).toBe("app");
});

test("a New Tab that inherited a project folder names the folder its host starts the chat in", async () => {
  expect(await mount("/Users/you/src/app", "/Users/you/src/app")).toBe("app");
});

// With no start folder from the host yet, a prompt starts in the private agent-home folder (App's
// chat.new fills none): the chip asks for a project rather than name the inherited folder.
test("before the host names a start folder, the chip asks for a project", async () => {
  expect(await mount("/Users/you/src/app")).toBe("Choose folder");
});

// Leo 2026-10-19: the first frame showed "Choose folder", then the project the tab inherited once
// the handshake named it. Before the handshake answers, the chip names that project (the handshake
// starts the chat there); the home folder is still never one.
test("before the handshake answers, an inherited project shows at once; the home folder does not", async () => {
  expect(await mount("/Users/you/src/app", undefined, true)).toBe("app");
  act(() => root?.unmount());
  root = undefined;
  expect(await mount("/Users/you", undefined, true)).toBe("Choose folder");
});
