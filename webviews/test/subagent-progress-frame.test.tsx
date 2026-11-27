// l10n-allow-file: synthetic agents for the coordinator-chat regression.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  AgentProgressContext,
  AgentProgressStore,
  useAgentProgress,
} from "../src/agent-session/acpmux/subagents/agentProgressStore";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { teardownDom } from "./support/domTeardown";
import { LiveUpdatesContext } from "../src/ui/liveUpdates";
import { pageClocks, usePageNow, useDeadlineNow } from "../src/ui/pageClock";

const dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/", pretendToBeVisual: true });
const frames = new Map<number, FrameRequestCallback>();
let nextFrame = 0;
const scope = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  IS_REACT_ACT_ENVIRONMENT: true,
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    frames.set(++nextFrame, callback);
    return nextFrame;
  },
  cancelAnimationFrame: (id: number) => frames.delete(id),
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(async () => teardownDom(saved, { window: dom.window, scope }));

async function frame() {
  await act(async () => {
    const ready = [...frames.values()];
    frames.clear();
    for (const callback of ready) callback(0);
  });
}

test("twenty agents' usage updates draw nothing; progress bursts draw once per frame", async () => {
  const agents = Array.from(
    { length: 20 },
    (_, i) => ({ id: `agent-${i}`, name: `Agent ${i}`, state: "running", startedAt: 1_000 }) as Subagent,
  );
  const store = new AgentProgressStore(agents);
  const renders = new Map<string, number>();
  function Progress({ agent }: { agent: Subagent }) {
    const text = useAgentProgress(agent);
    renders.set(agent.id, (renders.get(agent.id) ?? 0) + 1);
    return <span data-agent={agent.id}>{text}</span>;
  }
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <AgentProgressContext.Provider value={store}>
          {agents.map((agent) => (
            <Progress key={agent.id} agent={agent} />
          ))}
        </AgentProgressContext.Provider>,
      ),
    );
    renders.clear();
    for (let tick = 1; tick <= 10; tick++) {
      await act(async () => {
        for (const agent of agents) store.updateProgress(agent.id, { tokens: tick * 1_000, toolUses: tick });
      });
    }
    await frame();
    expect([...renders.values()]).toEqual([]);
    for (let done = 1; done <= 10; done++) {
      await act(async () => {
        for (const agent of agents) store.updateProgress(agent.id, { agents: { started: 20, done } });
      });
    }
    // The model is current immediately; UI delivery waits for one shared frame.
    expect(store.get(agents[0].id).agents?.done).toBe(10);
    expect([...renders.values()]).toEqual([]);
    expect(frames.size).toBe(1);
    await frame();
    expect([...renders.values()]).toEqual(Array.from({ length: 20 }, () => 1));
    expect(document.querySelector("[data-agent]")?.textContent).toContain("10");
    await act(async () => store.updateProgress(agents[0].id, { agents: { started: 20, done: 11 } }));
  } finally {
    await act(async () => root.unmount());
  }
  expect(frames.size).toBe(0);
});

test("offscreen retained rows have no clock or progress work and catch up when revealed", async () => {
  const agent = { id: "retained", name: "Retained", state: "running", startedAt: 1_000 } as Subagent;
  const store = new AgentProgressStore([agent]);
  let now = 1_000;
  const clock = () => now;
  const next = (at: number) => at + 60_000;
  let renders = 0;
  function Row() {
    const elapsed = usePageNow(true, clock);
    const deadline = useDeadlineNow(next);
    const progress = useAgentProgress(agent);
    renders++;
    return (
      <span data-time={elapsed} data-deadline={deadline}>
        {progress}
      </span>
    );
  }
  const root = createRoot(document.getElementById("root")!);
  const render = (active: boolean) =>
    root.render(
      <LiveUpdatesContext.Provider value={active}>
        <AgentProgressContext.Provider value={store}>
          <Row />
        </AgentProgressContext.Provider>
      </LiveUpdatesContext.Provider>,
    );
  try {
    await act(async () => render(true));
    expect(pageClocks().subscribers).toBe(2);
    await act(async () => render(false));
    const before = renders;
    expect(pageClocks().subscribers).toBe(0);
    now = 30_000;
    for (let done = 1; done <= 20; done++) {
      await act(async () => store.updateProgress(agent.id, { agents: { started: 20, done } }));
    }
    expect(frames.size).toBe(0);
    expect(renders).toBe(before);
    await act(async () => render(true));
    expect(document.querySelector("[data-time]")?.getAttribute("data-time")).toBe("30000");
    expect(document.body.textContent).toContain("20");
    expect(pageClocks().subscribers).toBe(2);
  } finally {
    await act(async () => root.unmount());
  }
  expect(pageClocks().subscribers).toBe(0);
});
