// l10n-allow-file: workflow and process clock fixtures.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { rowRenders } from "./support/commitRenders";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost",
  pretendToBeVisual: true,
});
const { window } = dom;
const scope = globalThis as Record<string, unknown>;
const globals = {
  window,
  document: window.document,
  navigator: window.navigator,
  HTMLElement: window.HTMLElement,
  Element: window.Element,
  Node: window.Node,
  MutationObserver: window.MutationObserver,
  getComputedStyle: window.getComputedStyle.bind(window),
  requestAnimationFrame: window.requestAnimationFrame.bind(window),
  cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, globals);
const { createRoot } = await import("react-dom/client");
const { WorkflowCard } = await import("../src/agent-session/acpmux/summary/WorkflowCard");
const { WorkflowSummaries } = await import("../src/agent-session/acpmux/summary/WorkflowSummary");
const { WorkflowSideTab } = await import("../src/agent-session/acpmux/summary/WorkflowSideTab");
const { workflowFixture } = await import("../src/agent-session/acpmux/summary/workflowFixture");
const { workflowOf } = await import("../src/agent-session/acpmux/summary/foldWorkflows");
const { TasksSection } = await import("../src/agent-session/acpmux/session-info/TasksSection");
const { ServersSection } = await import("../src/agent-session/acpmux/session-info/ServersSection");
const { WorkflowTasks } = await import("../src/agent-session/acpmux/session-info/WorkflowTasks");
const { AgentsPill } = await import("../src/agent-session/acpmux/subagents/AgentsPill");
const { SubagentClockContext } = await import("../src/agent-session/acpmux/subagents/subagentGroupModel");
const { LiveUpdatesContext } = await import("../src/ui/liveUpdates");
const host = window.document.getElementById("root")!;
const noop = () => {};
let root: Root;
beforeAll(() => {
  root = createRoot(host);
});
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { scope });
});

const advance = (ms: number) =>
  act(() => {
    jest.advanceTimersByTime(ms);
  });

test("elapsed labels tick without redrawing workflow chrome or agent and process text", () => {
  jest.useFakeTimers();
  try {
    const offset = -60_000;
    const now = Date.now() - offset;
    const startedAt = now - 5_000;
    const node = { ...workflowFixture("parallel", now).find((agent) => agent.kind === "workflow")!, startedAt };
    const folded = workflowOf(node, "session");
    const workflow = {
      ...folded,
      agents: folded.agents.map((agent) => (agent.state === "running" ? { ...agent, startedAt } : agent)),
    };
    let summaryReads = 0;
    const actionsFor = () => {
      summaryReads++;
      return {};
    };
    act(() =>
      root.render(
        <SubagentClockContext value={offset}>
          <WorkflowCard node={node} />
          <LiveUpdatesContext value={false}>
            <div data-offscreen>
              <WorkflowCard node={node} />
            </div>
          </LiveUpdatesContext>
          <WorkflowSummaries workflows={[workflow]} actionsFor={actionsFor} />
          <WorkflowSideTab workflow={workflow} onClose={noop} onOpenWorkflowAgent={noop} />
          <WorkflowTasks workflows={[workflow]} />
          <TasksSection commands={[{ id: "task", command: "test", state: "running", startedAt }]} />
          <ServersSection servers={[{ id: "server", command: "vite", state: "running", startedAt, ports: [] }]} />
          <AgentsPill
            agents={[{ id: "helper", parent: null, name: "Helper", state: "running", startedAt }]}
            waiting={new Set()}
            tones={new Map()}
            onOpen={noop}
          />
        </SubagentClockContext>,
      ),
    );
    act(() => host.querySelector<HTMLButtonElement>(".acpmux-agents-pill")!.click());
    const labels = [
      ".acpmux-workflow-card__meta .ui-clock",
      ".acpmux-workflow__row",
      ".acpmux-workflow-side-tab time",
      ".acpmux-workflow-agent[data-state=running] .acpmux-session-info-task__time",
      ".acpmux-workflow-task__head .acpmux-session-info-task__time",
      '[data-section="tasks"] .ui-clock',
      '[data-section="servers"] .ui-clock',
      ".acpmux-agents-list__time",
    ];
    const text = (selector: string) => host.querySelector(selector)?.textContent;
    for (const selector of labels) expect(text(selector), selector).toContain("5s");
    const accessible = host.querySelector(".acpmux-workflow-agent[data-state=running] button[aria-label]")!;
    expect(accessible.getAttribute("aria-label")).toContain("5s");

    const counter = rowRenders();
    const stable = [
      ".acpmux-workflow-card__head",
      ".acpmux-workflow-card__latest",
      ".acpmux-workflow__title",
      ".acpmux-workflow-agent__name",
      ".acpmux-session-info-task__command",
      ".acpmux-agents-list__name",
    ];
    for (const selector of stable) expect(host.querySelector(selector)).toBeTruthy();
    const before = summaryReads;
    counter.begin(host, stable.join(","));
    advance(1_000);
    expect(counter.end()).toEqual({ rerendered: 0, wasted: 0, added: 0, maxRenders: 0 });
    expect(summaryReads).toBe(before);
    for (const selector of labels) expect(text(selector), selector).toContain("6s");
    expect(accessible.getAttribute("aria-label")).toContain("6s");
    expect(text("[data-offscreen] .ui-clock")).toBe("5s");
  } finally {
    act(() => root.render(null));
    jest.useRealTimers();
  }
});

test("workflow idle and capacity signals update at their deadlines on a peer's clock", () => {
  jest.useFakeTimers();
  try {
    const offset = -60_000;
    const now = Date.now() - offset;
    const node = workflowFixture("parallel", now).find((agent) => agent.kind === "workflow")!;
    const folded = workflowOf(node, "session");
    const workflow = {
      ...folded,
      agents: folded.agents.map((agent) => ({ ...agent, lastProgressAt: now - 116_500 })),
    };
    const errors = ["one", "two"].map((agentId) => ({
      daemonId: "daemon",
      agentId,
      at: now - 117_500,
      reason: "429 exhausted",
    }));
    act(() =>
      root.render(
        <SubagentClockContext value={offset}>
          <WorkflowSummaries workflows={[workflow]} daemonCapacity={{ daemonId: "daemon", errors }} />
        </SubagentClockContext>,
      ),
    );
    act(() => host.querySelector<HTMLButtonElement>(".acpmux-workflow__row")!.click());
    const capacity = () => host.querySelector(".acpmux-workflow__warning output");
    const idle = () => host.querySelector(".acpmux-workflow__agent output");
    expect(capacity()).toBeTruthy();
    expect(idle()).toBeNull();
    advance(2_500);
    expect(capacity()).toBeTruthy();
    advance(10);
    expect(capacity()).toBeNull();
    expect(idle()).toBeNull();
    advance(1_000);
    expect(idle()).toBeTruthy();
  } finally {
    act(() => root.render(null));
    jest.useRealTimers();
  }
});
