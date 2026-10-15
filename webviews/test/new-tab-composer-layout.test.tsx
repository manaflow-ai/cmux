// The New Tab composer and the agent composer are one card (Leo 2026-10-13: the field, its
// selection and the project and model pickers under it read as illogical). As in the agent
// composer (Composer.tsx): the field on top, then the bar with the agent's model chip and Send,
// then the location row with the project, inside the same card. The project is never in the bar.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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

async function mount(options: { machineName?: string; snapshot?: AcpmuxSnapshot } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={options.snapshot ?? noChat()}
        {...(options.machineName ? { machineName: options.machineName } : {})}
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

test("the New Tab card is the composer's: the project strip on its top edge, then field, model and Send", async () => {
  await mount();
  const composer = host.querySelector<HTMLElement>(".nt-composer")!;
  const card = composer.querySelector<HTMLElement>(".nt-box")!;
  const parts = [
    ...composer.querySelectorAll<HTMLElement>(".acpmux-composer-strip, .nt-field, .acpmux-chips, .nt-send"),
  ];
  expect(parts.map((part) => part.className.split(" ")[0])).toEqual([
    "acpmux-composer-strip",
    "nt-field",
    "acpmux-chips",
    "acpmux-send",
  ]);
  // The project is the location strip's (hq#1957 composer location strip), as in the agent
  // composer: never in the card or its bar.
  const row = composer.querySelector<HTMLElement>(".acpmux-composer-strip .acpmux-composer-context")!;
  expect(row.textContent).toContain("app");
  expect(card.querySelector(".acpmux-composer-context, .acpmux-location-button")).toBeNull();
});

// Review (#20148): the composer's Computer menu listed a remote chat's machine, so the row could
// name it while Return started the chat on this one. A New Tab chat starts where the page runs:
// the row names that machine as the host does, and offers no other.
test("the location row names the machine the chat starts on and offers no other", async () => {
  const [local] = manySessions(1);
  const remote = { ...local!, sessionId: "remote-1", peer: "devbox", cwd: "/home/you/api" };
  await mount({ machineName: "studio", snapshot: noChat([local!, remote]) });
  const row = host.querySelector<HTMLElement>(".acpmux-composer-context")!;
  expect(row.textContent).toContain("studio");
  expect(row.textContent).not.toContain("This Mac");
  const computer = row.querySelector<HTMLButtonElement>('button[aria-label="Computer: studio"]');
  expect(computer).not.toBeNull();
  await act(async () => computer!.click());
  const options = [...document.querySelectorAll(".acpmux-menu-label")].map((item) => item.textContent);
  expect(options).toContain("studio");
  expect(options).not.toContain("devbox");
});
