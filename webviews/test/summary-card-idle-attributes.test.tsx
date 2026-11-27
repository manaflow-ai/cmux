// An idle chat changes nothing in the summary card but the running subagents' times. The Subagents
// section re-renders on the page clock each second, and React 19 writes an input's `name` and `type`
// on every render of it (ReactDOMInput `updateInput`: `name = ""`, `type`, then `removeAttribute("name")`),
// so the "Open subagents in panes" checkbox under that clock was rewritten every tick: 30 of the
// card body's ~50 mutations per 10 s in chat-100k-flat CASES=coordinator, each one an edge mark
// (scrollEdges.ts) on the card's scroller. A tick that changes nothing must write nothing.
// Leo, 2026-11-14: "the dream is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
import { afterEach, expect, jest, setSystemTime, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { SubagentStatusList } from "../src/agent-session/acpmux/summary/SubagentStatusList";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
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
  jest.useRealTimers();
  setSystemTime();
});

const agent = (id: string, state: string, startedAt: number, endedAt?: number): Subagent => ({
  id,
  parent: null,
  name: id,
  state,
  startedAt,
  ...(endedAt !== undefined ? { endedAt } : {}),
});

/// The page's own switch setter (subagents/subagentPanes.ts `setAutoOpen`) is one module function.
const setAutoOpen = (_on: boolean) => {};

test("ten idle seconds tick the subagent times and write no attribute to the open-in-panes checkbox", async () => {
  jest.useFakeTimers();
  setSystemTime(new Date(100_000));
  const container = installDom();
  // A coordinator's card: one subagent still running (its time ticks), the rest done.
  const agents = [
    agent("runner", "running", 99_000),
    ...Array.from({ length: 4 }, (_, i) => agent(`done-${i}`, "completed", 1_000 + i, 2_000 + i)),
  ];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SubagentStatusList
        agents={agents}
        waiting={new Set()}
        onOpen={() => {}}
        autoOpen={{ on: false, set: setAutoOpen }}
      />,
    );
  });
  const section = container.querySelector<HTMLElement>("section.acpmux-summary-agents")!;
  const checkbox = section.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
  expect(checkbox.getAttribute("aria-label")).toBe("Open subagents in panes");
  const time = () => section.querySelector(".acpmux-summary-list li")?.textContent ?? "";
  const before = time();

  const records: MutationRecord[] = [];
  const observer = new dom!.window.MutationObserver((batch) => records.push(...batch));
  observer.observe(section, { attributes: true, characterData: true, childList: true, subtree: true });
  for (let second = 0; second < 10; second++) await act(async () => void jest.advanceTimersByTime(1_000));
  records.push(...observer.takeRecords());
  observer.disconnect();

  // The clock did tick: the running subagent's time moved on.
  expect(time()).not.toBe(before);
  const written = records
    .filter((record) => record.type === "attributes" && record.target === checkbox)
    .map((record) => record.attributeName);
  expect(written).toEqual([]);
  // Nothing in the section but text changed: no attribute anywhere was rewritten.
  expect(records.filter((record) => record.type === "attributes").map((record) => record.attributeName)).toEqual([]);
  // What the person sees is the same checkbox.
  expect(checkbox.isConnected).toBe(true);
  expect(checkbox.type).toBe("checkbox");
  expect(checkbox.hasAttribute("name")).toBe(false);
  expect(checkbox.checked).toBe(false);
});

test("the open-in-panes checkbox still follows its setting and reports a click", async () => {
  const container = installDom();
  const set: boolean[] = [];
  const draw = (on: boolean) => (
    <SubagentStatusList
      agents={[agent("runner", "running", Date.now())]}
      waiting={new Set()}
      onOpen={() => {}}
      autoOpen={{ on, set: (next) => void set.push(next) }}
    />
  );
  await act(async () => {
    root = createRoot(container);
    root.render(draw(false));
  });
  const checkbox = container.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
  expect(checkbox.checked).toBe(false);
  await act(async () => checkbox.click());
  expect(set).toEqual([true]);
  await act(async () => root!.render(draw(true)));
  expect(checkbox.checked).toBe(true);
  await act(async () => checkbox.click());
  expect(set).toEqual([true, false]);
});
