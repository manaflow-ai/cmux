// Settings > Advanced > Experiments > Started Tasks: Title Opens Chat (off by default). Leo
// 2026-11-05: "subagents need to have their clickable bit be highlighted instead of the whole line
// click sending me to the subagent righ split". Off keeps today's whole-row button; on, the title
// chip is the one control that opens the chat.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionOffer } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  const { setExperimentSwitches } = await import("../src/experiments/switches");
  act(() => {
    setExperimentSwitches({});
    root?.unmount();
  });
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const offer: AcpmuxSessionOffer = {
  offerId: "offer-1",
  title: "Cart: add width and height to thumbnails",
  prompt: "Add dimensions.",
  cwd: "/Users/you/Projects/storefront",
  worktree: false,
  outcome: "accepted",
  childSessionId: "child-1",
  childStatus: "running",
  activity: "Reading CartLineItem.tsx",
};

async function render(on: boolean, opened: string[]) {
  const { createRoot } = await import("react-dom/client");
  const { SuggestedTasks } = await import("../src/agent-session/acpmux/offer/SuggestedTasks");
  const { setExperimentSwitches } = await import("../src/experiments/switches");
  setExperimentSwitches({ startedTaskTitleChip: on });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <SuggestedTasks
        offers={[offer]}
        actions={{
          start: async () => undefined,
          here: async () => undefined,
          dismiss: async () => undefined,
          open: (child) => void opened.push(child),
          reserve: async () => "ticket",
        }}
      />,
    ),
  );
}

test("off: the started task is today's whole-row button", async () => {
  const opened: string[] = [];
  await render(false, opened);
  const row = host.querySelector<HTMLButtonElement>("button.acpmux-task-row");
  expect(row).not.toBeNull();
  expect(host.querySelector(".acpmux-task-started .cv-agent-tag")).toBeNull();
  await act(async () => row!.click());
  expect(opened).toEqual(["child-1"]);
});

test("on: only the title chip opens the chat; the row is no button", async () => {
  const opened: string[] = [];
  await render(true, opened);
  expect(host.querySelector("button.acpmux-task-row")).toBeNull();
  const row = host.querySelector<HTMLElement>(".acpmux-task-started[data-title-chip] > .acpmux-task-row")!;
  expect(row).not.toBeNull();
  const chip = row.querySelector<HTMLButtonElement>("button.cv-agent-tag.is-open")!;
  expect(chip).not.toBeNull();
  expect(chip.textContent).toContain(offer.title);
  expect(row.querySelectorAll("button")).toHaveLength(1);
  await act(async () => row.querySelector<HTMLElement>(".acpmux-task-row-sub")!.click());
  expect(opened).toEqual([]);
  await act(async () => chip.click());
  expect(opened).toEqual(["child-1"]);
});
