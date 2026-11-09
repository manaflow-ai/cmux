// The model chip's right-click inside the chat composer (Leo 2026-11-08: "we can keep this as
// defualt for now but let's add toggle and make right clicking the model picker let you
// customize"). Review F1 on #39080: the composer's own right-click handler (composerChipMenu.ts,
// cx-2lm4) opened the model picker on a right-click of the model chip, so the customize menu never
// showed in a real chat. The model chip keeps its own right-click menu there; every other menu chip
// still opens its own menu on a right-click. The real Composer in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "MouseEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const node of document.body.querySelectorAll(".ui-context-menu-backdrop, .acpmux-mp")) node.remove();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

const menuItem = (label: string) =>
  [...document.querySelectorAll<HTMLElement>("[role^='menuitem']")].find(
    (row) => row.querySelector(".ui-menu-label")?.textContent?.trim() === label,
  );

async function rightClick(element: Element) {
  await act(async () => {
    element.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 4, clientY: 4 }),
    );
  });
  await settle();
}

test("the model chip's right-click opens Show Provider Logo and Show Effort; another chip's opens that chip", async () => {
  const { resetModelChipLookForTests } = await import("../src/agent-session/acpmux/modelChipLook");
  resetModelChipLookForTests();
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  let otherOpened = 0;
  function Chips() {
    return (
      <div className="acpmux-chips">
        <ModelPicker
          catalog={[{ id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }], pickable: true }]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
        />
        <button type="button" className="other-chip" aria-haspopup="menu" onClick={() => (otherOpened += 1)}>
          Other
        </button>
      </div>
    );
  }
  const snapshot = noChat([], {
    sessionId: "chip-menu",
    summary: { sessionId: "chip-menu", harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await settle();
  const chip = () => host.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button")!;
  expect(chip()).not.toBeNull();
  await rightClick(chip());
  expect(menuItem("Show Provider Logo")).not.toBeUndefined();
  expect(menuItem("Show Effort")).not.toBeUndefined();
  // The picker itself stays closed: the right-click is the customize menu's.
  expect(chip().getAttribute("aria-expanded")).not.toBe("true");
  expect(document.querySelector(".acpmux-mp")).toBeNull();
  await act(async () => menuItem("Show Provider Logo")!.click());
  await settle();
  expect(host.querySelector(".acpmux-model")!.getAttribute("data-chip-logo")).toBe("off");
  // Any other menu chip keeps cx-2lm4: its right-click opens its own menu.
  await rightClick(host.querySelector(".other-chip")!);
  expect(otherOpened).toBe(1);
  expect(menuItem("Show Provider Logo")).toBeUndefined();
});
