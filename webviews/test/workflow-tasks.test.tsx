// l10n-allow-file: fixture workflow names in assertions, not shipped UI.
// Session Info's Background tasks lists the chat's Claude workflows (Labs): a running one with
// its counts, tokens, description, phases with a dot per agent, the running phase open with its
// model and agents, and the phases no agent started yet as plain rows with no label (Leo,
// 2026-10-29: "I fucking hate it when you guys narrate so much bullshit"); a finished one as "Workflow · Finished · 7 agents", its phases
// N/N, each opening into its agents. The data is a workflow's events fed through the real fold.
import { afterEach, expect, test } from "bun:test";
import { pageClocks } from "../src/ui/pageClock";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { WorkflowAgentRow, WorkflowTasks } from "../src/agent-session/acpmux/session-info/WorkflowTasks";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { finishedTrayItems, trayItems, withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { SUBAGENT_DONE, WORKFLOW_CARD } from "../src/agent-session/acpmux/subagents/subagentRows";
import { WorkflowCard } from "../src/agent-session/acpmux/summary/WorkflowCard";
import { WorkflowSideTab } from "../src/agent-session/acpmux/summary/WorkflowSideTab";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { createWorkflowAdapter, modelName, phaseState, tally } from "../src/agent-session/acpmux/summary/foldWorkflows";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";

const NOW = 1_800_000_000_000;
const summaries = (stage: "running" | "finished") => createWorkflowAdapter()(workflowFixture(stage, NOW), "s1");
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("the adapter derives each phase's state and counts, and the model's name", () => {
  const [workflow] = summaries("running");
  expect(workflow!.description).toStartWith("Demo: 3 agents brainstorm names");
  expect(workflow!.phases.map((phase) => phase.state)).toEqual(["completed", "running", "pending"]);
  expect(tally(workflow!.agents)).toEqual({ running: 1, queued: 2, done: 3, failed: 0, total: 6 });
  expect(workflow!.agents[0]!.model).toBe("claude-opus-5-5");
  expect(phaseState([])).toBe("pending");
  expect([
    modelName("claude-opus-5-5"),
    modelName("sonnet"),
    modelName("claude-haiku-4-5-20251001"),
    modelName("gpt-6"),
  ]).toEqual(["Opus 5.5", "Sonnet", "Haiku 4.5", "Gpt 6"]);
});

test("a running workflow shows its counts, tokens, description, phases, the open running phase and the next phase as a row", () => {
  const html = renderToStaticMarkup(<WorkflowTasks workflows={summaries("running")} onStop={async () => undefined} />);
  const shown = text(html);
  // One group: the section's head counts it, so no group head.
  expect(html).not.toContain("acpmux-workflow-tasks__group");
  expect(shown).toContain("demo-name-tournament");
  expect(shown).toContain("1 running · 2 queued · 3 done · 185k tokens");
  expect(shown).toContain("Demo: 3 agents brainstorm names");
  expect(shown).toContain("Brainstorm 3 done");
  // The phase with a running agent is open: its model once, its agents with how long or Queued.
  expect(shown).toContain("Critique 1 running · 2 queued punchy Model: Opus 5.5");
  expect(shown).toContain("playful Model: Opus 5.5 Queued descriptive Model: Opus 5.5 Queued");
  // Judge has no agent yet: a phase row in its pending state, with nothing to open, and no "Up next" line.
  expect(html.match(/class="acpmux-workflow-phase"/g)?.length).toBe(3);
  expect(html).toContain('<li class="acpmux-workflow-phase" data-state="pending">');
  expect(shown).not.toContain("Up next");
  expect(shown).toMatch(/Judge$/);
  const judge = /<li class="acpmux-workflow-phase" data-state="pending">.*?<\/li>/.exec(html)![0];
  expect(judge).toContain("disabled");
  expect(judge).not.toContain("data-icon");
  expect(html.match(/acpmux-workflow-dot"/g)?.length).toBe(6);
  expect(html).toContain('aria-label="Stop demo-name-tournament"');
});

test("workflow agent rows never send a workflow agent id to the ordinary subagent opener", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const workflow = summaries("running")[0]!;
  const agent = workflow.agents[0]!;
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  let legacyOpened = false;
  await act(async () =>
    root!.render(
      <WorkflowAgentRow workflow={workflow} agent={agent} now={NOW} onOpenSubagent={() => (legacyOpened = true)} />,
    ),
  );
  expect(container.querySelector("button")).toBeNull();
  const row = container.querySelector(".acpmux-workflow-agent__button") as HTMLElement;
  expect(row.tagName).toBe("DIV");
  await act(async () => row.click());
  expect(legacyOpened).toBe(false);
});

test("the shipped Session Info renders workflow agents as normal content until a workflow opener is supplied", () => {
  for (const variant of ["compact", "detail", "grid"] as const) {
    const document = new JSDOM(
      renderToStaticMarkup(
        <SessionInfo
          workflows={summaries("running")}
          onStopWorkflow={async () => undefined}
          onOpenSubagent={() => undefined}
          workflowAgentRowVariant={variant}
        />,
      ),
    );
    const rows = document.window.document.querySelectorAll(".acpmux-workflow-agent");
    expect(rows.length).toBe(3);
    for (const row of rows) {
      expect(row.querySelector("button, [role], [disabled], [aria-disabled], [tabindex], [aria-label]")).toBeNull();
      expect(text(row.innerHTML)).toContain("Model: Opus 5.5");
    }
    document.window.close();
  }
});

test("Session Info renders enabled workflow buttons when a workflow opener is supplied", () => {
  const document = new JSDOM(
    renderToStaticMarkup(<SessionInfo workflows={summaries("running")} onOpenWorkflowAgent={() => undefined} />),
  );
  const buttons = document.window.document.querySelectorAll<HTMLButtonElement>(".acpmux-workflow-agent button");
  expect(buttons.length).toBe(3);
  for (const button of buttons) expect(button.disabled).toBe(false);
  document.window.close();
});

test("a queued workflow agent is inert without an agent id and a button with one", () => {
  const [workflow] = summaries("running");
  const queued = workflow!.agents.find((agent) => agent.state === "waiting")!;
  const withoutAgentId = renderToStaticMarkup(
    <WorkflowAgentRow
      workflow={workflow!}
      agent={{ ...queued, agentId: undefined }}
      now={NOW}
      onOpenWorkflowAgent={() => undefined}
    />,
  );
  expect(withoutAgentId).not.toContain("<button");
  expect(withoutAgentId).toContain('<div class="acpmux-workflow-agent__button');
  const withAgentId = renderToStaticMarkup(
    <WorkflowAgentRow workflow={workflow!} agent={queued} now={NOW} onOpenWorkflowAgent={() => undefined} />,
  );
  expect(withAgentId).toContain("<button");
});

test("every workflow row exposes model, effort, last message, state and duration to assistive technology", () => {
  const workflow = summaries("running")[0]!;
  const agent = {
    ...workflow.agents[0]!,
    effort: "high",
    doing: "Reading the source",
    lastMessage: "Review complete",
  };
  for (const variant of ["compact", "detail", "grid"] as const) {
    const document = new JSDOM(
      renderToStaticMarkup(
        <WorkflowAgentRow
          workflow={workflow}
          agent={agent}
          now={NOW}
          variant={variant}
          onOpenWorkflowAgent={() => undefined}
        />,
      ),
    );
    expect(document.window.document.querySelector("button")?.getAttribute("aria-label")).toBe(
      "punchy, Model: Opus 5.5 · high, Review complete, Done, 7s",
    );
    document.window.close();
    const plain = new JSDOM(
      renderToStaticMarkup(<WorkflowAgentRow workflow={workflow} agent={agent} now={NOW} variant={variant} />),
    );
    expect(text(plain.window.document.body.innerHTML)).toBe("punchy Model: Opus 5.5 · high Review complete Done 7s");
    plain.window.close();
  }
});

test("a workflow agent row sends the full agent to the workflow opener", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const workflow = summaries("running")[0]!;
  const agent = workflow.agents[0]!;
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  let opened: typeof agent | undefined;
  await act(async () =>
    root!.render(
      <WorkflowAgentRow
        workflow={workflow}
        agent={agent}
        now={NOW}
        onOpenWorkflowAgent={(value) => (opened = value)}
      />,
    ),
  );
  const button = container.querySelector("button") as HTMLButtonElement;
  expect(button.disabled).toBe(false);
  await act(async () => button.click());
  expect(opened).toBe(agent);
});

test("the side tab opens transcript-able agents and leaves queued agents without ids inert", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const workflow = summaries("running")[0]!;
  const target = workflow.agents.find((agent) => agent.state === "running")!;
  const queued = workflow.agents.find((agent) => agent.state === "waiting")!;
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  let opened: typeof target | undefined;
  await act(async () =>
    root!.render(
      <WorkflowSideTab
        workflow={{
          ...workflow,
          agents: workflow.agents.map((agent) => (agent.id === queued.id ? { ...agent, agentId: undefined } : agent)),
        }}
        onClose={() => undefined}
        onOpenWorkflowAgent={(agent) => (opened = agent)}
      />,
    ),
  );
  const targetButton = container.querySelector<HTMLButtonElement>(
    '.acpmux-workflow-agent[data-state="running"] button',
  );
  expect(targetButton).toBeDefined();
  await act(async () => targetButton!.click());
  expect(opened).toBe(target);
  const queuedRow = container.querySelector<HTMLElement>('.acpmux-workflow-agent[data-state="waiting"]');
  expect(queuedRow?.querySelector("button")).toBeNull();
  expect(queuedRow?.querySelector(".acpmux-workflow-agent__button")?.tagName).toBe("DIV");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("a finished workflow reads as finished with its size, and a phase opens into its agents", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(<WorkflowTasks workflows={summaries("finished")} />));
  const shown = () => text(container.innerHTML);
  expect(shown()).toContain("demo-name-tournament 1m 20s Workflow · Finished · 7 agents · 432k tokens");
  expect(shown()).toContain("Brainstorm 3/3 Critique 3/3 Judge 1/1");
  expect(shown()).not.toContain("Up next");
  expect(container.querySelector("[aria-label='Stop demo-name-tournament']")).toBeNull();
  const judge = [...container.querySelectorAll("button")].find((button) => button.textContent?.startsWith("Judge"))!;
  await act(async () => judge.click());
  expect(shown()).toContain("Judge 1/1 judge Model: Opus 5.5 Done 41s");
});

test("a running workflow keeps its elapsed clock live before agent records arrive", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    value: "visible",
  });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const workflow = summaries("running")[0]!;
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(<WorkflowTasks workflows={[{ ...workflow, agents: [], phases: [] }]} />));
  // The elapsed clock is the page's shared second clock (ui/pageClock.ts), running for this page.
  expect(pageClocks().items.some((clock) => clock.name === "elapsed" && clock.running)).toBe(true);
});

test("with running and finished workflows, each group says how many it holds", () => {
  const [finished] = summaries("finished");
  const html = renderToStaticMarkup(
    <WorkflowTasks workflows={[...summaries("running"), { ...finished!, id: "earlier" }]} />,
  );
  expect(text(html)).toContain("1 running demo-name-tournament");
  expect(text(html)).toContain("1 finished demo-name-tournament");
});

test("blocked and skipped agents count as ended without finishing, never as unknown", () => {
  const nodes = workflowFixture("running", NOW).map((node) => {
    const agents = new Map(node.workflowAgents);
    agents.set(5, { ...agents.get(5)!, state: "blocked" });
    agents.set(6, { ...agents.get(6)!, state: "skipped" });
    return { ...node, workflowAgents: agents };
  });
  const [workflow] = createWorkflowAdapter()(nodes, "s1");
  expect(workflow!.agents.map((agent) => agent.state).slice(4)).toEqual(["failed", "cancelled"]);
  expect(tally(workflow!.agents)).toEqual({ running: 1, queued: 0, done: 3, failed: 2, total: 6 });
  expect(workflow!.phases[1]!.state).toBe("running");
});

test("the transcript card shows workflow progress, latest agent text, model, time and tokens", () => {
  const [node] = workflowFixture("running", NOW).filter((each) => each.kind === "workflow");
  const html = renderToStaticMarkup(<WorkflowCard node={{ ...node!, endedAt: node!.startedAt + 13_000 }} />);
  expect(text(html)).toContain("demo-name-tournament Running Critique 3/6 13s 185.1K tokens");
  expect(text(html)).toContain("The latest shortlist favors names that read clearly at a glance.");
  expect(text(html)).toContain("claude-opus-5-5");
  expect(html).toContain('role="progressbar"');
  expect(html).toContain('aria-valuemin="0"');
  expect(html).toContain('aria-valuemax="6"');
  expect(html).toContain('aria-valuenow="3"');
  // No handler: the card is no button anyone can press.
  expect(html).toContain("disabled");
});

test("with Labs, a workflow a group started is a card in the group's place and leaves no done line", () => {
  const nodes = workflowFixture("finished", NOW);
  const plain = {
    ...nodes[0]!,
    id: "acp-1/toolu_plain",
    kind: "Explore",
    name: "Explore",
    workflowAgents: undefined,
  };
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: NOW - 200_000, kind: "user", text: "go" },
    { id: "g", version: 1, at: NOW - 120_000, kind: SUBAGENTS, subagents: [...nodes, plain] },
    { id: "a", version: 1, at: NOW - 10_000, kind: "assistant", text: "done" },
  ];
  const labs = withSubagentLines(rows, new Map(), true);
  expect(labs.map((row) => row.kind)).toEqual(["user", WORKFLOW_CARD, SUBAGENT_DONE, "assistant"]);
  expect(labs[1]!.subagents?.map((node) => node.id)).toEqual([nodes[0]!.id]);
  // A pause alone (the state kept, only the flag) draws the card again: its row's version moves.
  const cache = new Map();
  const first = withSubagentLines(rows, cache, true)[1]!;
  const paused = rows.map((row) =>
    row.kind === SUBAGENTS
      ? {
          ...row,
          subagents: row.subagents!.map((node) => (node.kind === "workflow" ? { ...node, paused: true } : node)),
        }
      : row,
  );
  expect(withSubagentLines(paused, cache, true)[1]!.version).not.toBe(first.version);
  expect(labs[2]!.subagents?.[0]!.id).toBe(plain.id);
  // Without Labs, the workflow is a done line like any subagent.
  expect(withSubagentLines(rows, new Map()).map((row) => row.kind)).toEqual([
    "user",
    SUBAGENT_DONE,
    SUBAGENT_DONE,
    "assistant",
  ]);
});

test("each workflow a group started is its own card row, so each row is one card tall", () => {
  const [node] = workflowFixture("finished", NOW);
  const rows: AcpmuxRow[] = [
    {
      id: "g",
      version: 1,
      at: NOW - 120_000,
      kind: SUBAGENTS,
      subagents: [node!, { ...node!, id: "acp-1/toolu_wf2" }],
    },
  ];
  const cards = withSubagentLines(rows, new Map(), true);
  expect(cards.map((row) => [row.kind, row.subagents?.length])).toEqual([
    [WORKFLOW_CARD, 1],
    [WORKFLOW_CARD, 1],
  ]);
});

test("a finished turn's fold keeps the workflow card outside it, where the workflow started", () => {
  const [node] = workflowFixture("finished", NOW);
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: NOW - 200_000, kind: "user", text: "go" },
    {
      id: "w1",
      version: 1,
      at: NOW - 190_000,
      kind: "activity",
      items: [{ kind: "tool", text: "Read a.ts" }],
      toolCount: 1,
    },
    { id: "g", version: 1, at: NOW - 180_000, kind: SUBAGENTS, subagents: [node!] },
    { id: "a", version: 1, at: NOW - 10_000, kind: "assistant", text: "done" },
    {
      id: "s",
      version: 1,
      at: NOW - 9_000,
      kind: "turnSummary",
      durationMs: 190_000,
      toolCount: 1,
    },
  ];
  const view = turnViewFrom(withSubagentLines(rows, new Map(), true), new Set(), { now: NOW });
  // The turn folded its work (the read) but the card is still drawn.
  expect(view.rows.some((row) => row.id === "w1")).toBe(false);
  expect(view.rows.some((row) => row.kind === WORKFLOW_CARD)).toBe(true);
});

test("with Labs, a workflow is in neither tray list, running or ended (App.tsx trayAgents)", () => {
  const running = workflowFixture("running", NOW);
  const finished = workflowFixture("finished", NOW);
  const plain = {
    ...finished[0]!,
    id: "acp-1/toolu_plain",
    kind: "Explore",
    name: "Explore",
    workflowAgents: undefined,
  };
  const labs = (agents: typeof running) => agents.filter((agent) => agent.kind !== "workflow");
  expect(trayItems(labs(running), [], [], true)).toEqual([]);
  expect(
    finishedTrayItems(labs([...finished, plain]), []).map((item) => (item.kind === "agent" ? item.agent.id : "")),
  ).toEqual([plain.id]);
  // Without Labs, both lists carry it, as before.
  expect(trayItems(running, [], [], true).length).toBe(1);
  expect(finishedTrayItems(finished, []).length).toBe(1);
});

test("failed workflow agents show their error instead of stale output in every row variant", () => {
  const workflow = summaries("running")[0]!;
  for (const variant of ["compact", "detail", "grid"] as const) {
    for (const stale of [{}, { lastMessage: "Earlier reply", doing: "Reading source" }]) {
      const agent = {
        ...workflow.agents[0]!,
        ...stale,
        state: "failed" as const,
        error: "503: No provider capacity available",
      };
      const document = new JSDOM(
        renderToStaticMarkup(
          <WorkflowAgentRow
            workflow={workflow}
            agent={agent}
            now={NOW}
            variant={variant}
            onOpenWorkflowAgent={() => undefined}
          />,
        ),
      );
      const message = document.window.document.querySelector(".acpmux-workflow-agent__doing");
      expect(message?.textContent).toBe(agent.error);
      expect(message?.getAttribute("title")).toBe(agent.error);
      expect(document.window.document.querySelector("button")?.getAttribute("aria-label")).toContain(agent.error);
      expect(document.window.document.body.textContent).not.toContain("Earlier reply");
      document.window.close();
    }
  }
});

test("a retried workflow agent shows its current action even when an earlier error remains", () => {
  const workflow = summaries("running")[0]!;
  const agent = {
    ...workflow.agents[0]!,
    state: "running" as const,
    error: "503: No provider capacity available",
    lastMessage: undefined,
    doing: "Retrying the review",
  };
  const html = renderToStaticMarkup(<WorkflowAgentRow workflow={workflow} agent={agent} now={NOW} />);
  expect(text(html)).toContain(agent.doing);
  expect(text(html)).not.toContain(agent.error);
});

test("a pending phase opens on its own when its first agent starts running, as a started phase did", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const before = summaries("running")[0]!;
  const judge = before.phases.find((phase) => phase.state === "pending")!;
  expect(judge.agentIds).toEqual([]);
  // The next update: Judge's first agent is running.
  const judgeAgent = { ...before.agents[0]!, id: "judge-1", name: "judge", state: "running" as const };
  const after = {
    ...before,
    agents: [...before.agents, judgeAgent],
    phases: before.phases.map((phase) =>
      phase.id === judge.id ? { ...phase, state: "running" as const, agentIds: [judgeAgent.id] } : phase,
    ),
  };
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  const judgeRow = () => [...container.querySelectorAll(".acpmux-workflow-phase")].at(-1)!;
  await act(async () => root!.render(<WorkflowTasks workflows={[before]} />));
  expect(judgeRow().querySelector(".acpmux-workflow-phase__agents")).toBeNull();
  await act(async () => root!.render(<WorkflowTasks workflows={[after]} />));
  expect(judgeRow().querySelector(".acpmux-workflow-phase__agents")).not.toBeNull();
  expect(judgeRow().querySelector("button")!.getAttribute("aria-expanded")).toBe("true");
});

test("a pending phase whose agents arrive queued opens when one of them starts running", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const before = summaries("running")[0]!;
  const judge = before.phases.find((phase) => phase.state === "pending")!;
  // Judge's agent is spawned but waits its turn, then starts.
  const withJudge = (state: "waiting" | "running") => ({
    ...before,
    agents: [...before.agents, { ...before.agents[0]!, id: "judge-1", name: "judge", state }],
    phases: before.phases.map((phase) =>
      phase.id === judge.id
        ? { ...phase, state: state === "running" ? ("running" as const) : phase.state, agentIds: ["judge-1"] }
        : phase,
    ),
  });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  const judgeRow = () => [...container.querySelectorAll(".acpmux-workflow-phase")].at(-1)!;
  await act(async () => root!.render(<WorkflowTasks workflows={[before]} />));
  await act(async () => root!.render(<WorkflowTasks workflows={[withJudge("waiting")]} />));
  expect(judgeRow().querySelector("button")!.getAttribute("aria-expanded")).toBe("false");
  await act(async () => root!.render(<WorkflowTasks workflows={[withJudge("running")]} />));
  expect(judgeRow().querySelector("button")!.getAttribute("aria-expanded")).toBe("true");
  expect(judgeRow().querySelector(".acpmux-workflow-phase__agents")).not.toBeNull();
});
