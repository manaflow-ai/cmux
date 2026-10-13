// The New Tab composer and the agent composer are one card (Leo 2026-10-13: the field, its
// selection and the project and model pickers under it read as illogical). As in the agent
// composer (Composer.tsx): the field on top, then the bar with the agent's model chip and Send,
// then the location row with the project, inside the same card. The project is never in the bar.
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

function Chips() {
  return <span className="acpmux-chips">Claude Opus 5.5</span>;
}

async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you"
        startCwd="/Users/you/src/app"
        projects={[{ cwd: "/Users/you/src/app", label: "app" }]}
        chips={Chips}
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
}

test("the New Tab card is the composer's: field, then model and Send, then the project row", async () => {
  await mount();
  const card = host.querySelector<HTMLElement>(".nt-box")!;
  const parts = [...card.querySelectorAll<HTMLElement>(".nt-field, .acpmux-chips, .nt-send, .acpmux-composer-context")];
  expect(parts.map((part) => part.className.split(" ")[0])).toEqual([
    "nt-field",
    "acpmux-chips",
    "acpmux-send",
    "acpmux-composer-context",
  ]);
  // The project is the location row's, as in the agent composer, and never in the bar.
  const row = card.querySelector<HTMLElement>(".acpmux-composer-context")!;
  expect(row.textContent).toContain("app");
  expect(card.querySelector('.nt-pickers [aria-label="Project"], .nt-pickers .acpmux-location-button')).toBeNull();
});
