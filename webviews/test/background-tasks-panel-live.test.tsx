// l10n-allow-file: test fixture names, not shipped UI.
// The Background tasks panel (backgroundTasks/BackgroundTasksPanel.tsx): a group whose own agent
// ended still runs while a nested agent of it does (spinner, live time, open at first), and a
// transcript opened before acpmux streamed any of its rows mounts one window of the rows that
// arrive, not every row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { BackgroundGroup } from "../src/agent-session/acpmux/backgroundTasks/backgroundTasks";
import { BackgroundTasksPanel } from "../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel";
import { SubagentTranscript, WINDOW } from "../src/agent-session/acpmux/backgroundTasks/SubagentTranscript";

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
    CSS: { escape: (value: string) => value },
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const rows = (n: number): AcpmuxRow[] =>
  Array.from({ length: n }, (_, index) => ({ id: `r${index}`, version: 1, at: index, kind: "assistant", text: "x" }));

test("a group whose agent ended runs while its nested agent does", async () => {
  const container = installDom();
  const group: BackgroundGroup = {
    id: "agent:a",
    kind: "agent",
    name: "Parent agent",
    state: "done",
    startedAt: 1_000,
    endedAt: 2_000,
    running: [{ id: "b", kind: "agent", title: "Nested agent", state: "running", startedAt: 1_500, agentId: "b" }],
    finished: [],
    total: 1,
    failed: 0,
    agentId: "a",
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel groups={[group]} onClearFinished={() => {}} onExpand={() => {}} onClose={() => {}} />,
    ),
  );
  const block = container.querySelector<HTMLElement>('[data-group="agent:a"]')!;
  expect(block.dataset.state).toBe("running");
  expect(block.querySelector(".acpmux-bg__name .cv-spinner")).not.toBeNull();
  expect(block.textContent).toContain("Nested agent");
});

test("a transcript opened before its rows arrive mounts one window of them", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<SubagentTranscript rows={[]} running />));
  await act(async () => root!.render(<SubagentTranscript rows={rows(500)} running />));
  expect(container.querySelectorAll("[data-row-id]").length).toBe(WINDOW);
});

test("a transcript that follows its newest row keeps its mounted rows bounded as rows stream in", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<SubagentTranscript rows={rows(60)} running />));
  await act(async () => root!.render(<SubagentTranscript rows={rows(400)} running />));
  expect(container.querySelectorAll("[data-row-id]").length).toBeLessThanOrEqual(2 * WINDOW);
});

test("a finished command with no known end shows no time that keeps counting", async () => {
  const container = installDom();
  const group: BackgroundGroup = {
    id: "commands",
    kind: "commands",
    name: "This chat",
    state: "done",
    startedAt: 1_000,
    running: [],
    finished: [{ id: "c", kind: "command", title: "bun test", state: "done", startedAt: 1_000 }],
    total: 1,
    failed: 0,
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel
        groups={[group]}
        look="flat"
        onClearFinished={() => {}}
        onExpand={() => {}}
        onClose={() => {}}
      />,
    ),
  );
  const times = [...container.querySelectorAll(".acpmux-bg__time")].map((node) => node.textContent ?? "");
  expect(times.length).toBeGreaterThan(0);
  expect(times.every((text) => text === "")).toBe(true);
});
