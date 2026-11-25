// The composer's Hybrid chip on the app's real `place`: Rust's `blocked` and `holders` (priority::control, carried by
// CloudPlaceFlows.placeJSON) reach the control, and a Signed Out click opens Sign In. Leo, 2026-11-23: "you guys need
// to be absolutely exhaustively testing out what would a new user be seeing here?"
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../../ui/UiProvider";
import { settleReact } from "../../../../test/support/domTeardown";
import { resetHeaderStateForTests, setHeaderState } from "../header/headerState";
import { HybridChip } from "./HybridMounts";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "MutationObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    CSS: { escape: (value: string) => value.replace(/[^\w-]/g, (char) => `\\${char}`) },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle,
    MutationObserver: dom.window.MutationObserver,
    // The holders' menu (Base UI) schedules its open transition on a frame.
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => resetHeaderStateForTests());
afterEach(async () => {
  resetHeaderStateForTests();
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function drawChip(): Promise<{ container: HTMLElement; calls: unknown[] }> {
  const container = installDom();
  const calls: unknown[] = [];
  (dom!.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = {
    "action.run": (params: unknown) => {
      calls.push(params);
      return Promise.resolve();
    },
  };
  root = createRoot(container);
  await act(async () => root!.render(<UiProvider container={container}>{<HybridChip session="s-1" />}</UiProvider>));
  return { container, calls };
}

const toggle = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-testid="hybrid-tri-toggle"]');

test("a signed-out place blocks the chip, and its click opens Sign In instead of moving the chat", async () => {
  setHeaderState({ place: { mode: "auto", at: "local", blocked: { why: "signed-out" } } });
  const { container, calls } = await drawChip();
  expect(toggle(container)?.getAttribute("data-blocked")).toBe("signed-out");
  const segment =
    container.querySelector<HTMLElement>('[role="radio"][data-mode="cloud"]') ??
    container.querySelector<HTMLElement>('[role="radio"]');
  await act(async () => segment!.click());
  expect(calls).toEqual([{ id: "palette.auth.signIn" }]);
});

test("a place whose slots are all held lists the holders by title; a place with neither is the plain chip", async () => {
  setHeaderState({
    place: { mode: "auto", at: "local", holders: [{ session: "h-1", title: "Port the settings page" }] },
  });
  const { container } = await drawChip();
  expect(toggle(container)?.getAttribute("data-blocked")).toBeNull();
  const name = container.querySelector<HTMLElement>(".acpmux-hybrid-tri__name, [aria-haspopup]");
  expect(name).not.toBeNull();
  await act(async () => name!.click());
  // The popover mounts a macrotask or two after the click: yield until its rows are in the document.
  const rows = () => [...container.ownerDocument.querySelectorAll(".acpmux-hybrid-holder__title")];
  for (let turn = 0; turn < 200 && rows().length === 0; turn++) {
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  const titles = rows().map((row) => row.textContent);
  expect(titles).toEqual(["Port the settings page"]);
});
