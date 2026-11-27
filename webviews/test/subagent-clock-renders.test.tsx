// l10n-allow-file: subagent clock and row fixtures.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
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
const { SubagentGroupHeader, SubagentListRow } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { AgentRunCard } = await import("../src/agent-session/acpmux/subagents/AgentRunCard");
const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
const { SubagentsSection } = await import("../src/agent-session/acpmux/session-info/SubagentsSection");
const { BackgroundTasksPanel } = await import("../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel");
const { SubagentClockContext } = await import("../src/agent-session/acpmux/subagents/subagentGroupModel");
const { IDLE_AFTER_MS } = await import("../src/agent-session/acpmux/subagents/idle");
const host = window.document.getElementById("root")!;
let root: Root;
const waiting = new Set<string>();
const noop = () => {};
beforeAll(() => {
  root = createRoot(host);
});
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { scope });
});

test("the page second advances elapsed text while group, row, card, summary and task labels stay cold", () => {
  jest.useFakeTimers();
  try {
    const offset = -60_000;
    const now = Date.now() - offset;
    const agents: Subagent[] = Array.from({ length: 128 }, (_, i) => ({
      id: String(i),
      parent: null,
      name: `Helper ${i}`,
      startedAt: now - 5_000,
      state: "running",
    }));
    const row: AcpmuxRow = {
      id: "group",
      version: 1,
      kind: "subagents",
      at: now,
      subagents: agents,
    };
    const agent = agents[0]!;
    act(() =>
      root.render(
        <SubagentClockContext value={offset}>
          <SubagentGroupHeader row={row} expanded onToggle={noop} />
          {agents.map((each) => (
            <SubagentListRow key={each.id} row={{ ...row, id: each.id, subagents: [each] }} />
          ))}
          <div data-card>
            <AgentRunCard agent={agent} />
          </div>
          <div data-summary>
            <SubagentStatusList agents={agents} waiting={waiting} />
          </div>
          <div data-info>
            <SubagentsSection agents={agents} waiting={waiting} />
          </div>
          <BackgroundTasksPanel
            onClearFinished={noop}
            groups={[
              {
                id: "agent:a",
                name: "Research",
                kind: "agent",
                state: "running",
                startedAt: agent.startedAt,
                total: 1,
                failed: 0,
                finished: [],
                running: [
                  {
                    id: "tool",
                    title: "Search",
                    kind: "tool",
                    state: "running",
                    startedAt: agent.startedAt,
                  },
                ],
              },
            ]}
          />
        </SubagentClockContext>,
      ),
    );
    const names = [
      ".cv-subagents__title",
      ".cv-subagent__name",
      ".cv-disclosure__label",
      "[data-summary] .acpmux-summary-agent__name",
      "[data-info] .acpmux-summary-agent__name",
      ".acpmux-bg__label",
    ];
    for (const selector of names) expect(host.querySelector(selector)).toBeTruthy();
    expect(host.querySelectorAll(".cv-subagent__name")).toHaveLength(128);
    const clocks = [
      ".cv-subagents__time",
      ".cv-subagent__time",
      "[data-card]",
      "[data-info] .acpmux-agent-line__time",
      "[data-summary] .acpmux-agent-line__time",
      ".acpmux-bg__time",
    ];
    for (const selector of clocks) expect(host.querySelector(selector)?.textContent).toContain("5s");
    const counter = rowRenders();
    counter.begin(host, names.join(","));
    act(() => {
      jest.advanceTimersByTime(1_000);
    });
    expect(counter.end()).toEqual({ rerendered: 0, wasted: 0, added: 0, maxRenders: 0 });
    for (const selector of clocks) expect(host.querySelector(selector)?.textContent).toContain("6s");
  } finally {
    act(() => root.render(null));
    jest.useRealTimers();
  }
});

test("Session Info changes state at the idle deadline and an unknown ended run has no time or separator", () => {
  jest.useFakeTimers();
  try {
    const now = Date.now();
    const agent: Subagent = {
      id: "a",
      parent: null,
      name: "Helper",
      state: "running",
      startedAt: now - IDLE_AFTER_MS,
      quietSince: now - IDLE_AFTER_MS + 2_000,
    };
    const ended: Subagent = { ...agent, state: "disconnected", startedAt: now, endedAt: now };
    act(() =>
      root.render(
        <>
          <SubagentsSection agents={[agent]} waiting={waiting} />
          <AgentRunCard agent={ended} />
        </>,
      ),
    );
    expect(host.querySelector(".acpmux-agent-line")?.getAttribute("data-status")).toBe("running");
    expect(host.querySelector(".cv-disclosure")?.textContent).not.toMatch(/0s| · /);
    act(() => {
      jest.advanceTimersByTime(2_010);
    });
    expect(host.querySelector(".acpmux-agent-line")?.getAttribute("data-status")).toBe("idle");
  } finally {
    act(() => root.render(null));
    jest.useRealTimers();
  }
});
