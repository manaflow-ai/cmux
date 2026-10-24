// l10n-allow-file: fixture workflow names in assertions, not shipped UI.
// The Inspector's Background tasks lists the chat's Claude workflows (Labs): a running one with
// its counts, tokens, description, phases with a dot per agent, the running phase open with its
// model and agents, and "Up next"; a finished one as "Workflow · Finished · 7 agents", its phases
// N/N, each opening into its agents. The data is a workflow's events fed through the real fold.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { WorkflowTasks } from "../src/agent-session/acpmux/inspector/WorkflowTasks";
import {
  createWorkflowAdapter,
  modelName,
  phaseState,
  tally,
  upNext,
} from "../src/agent-session/acpmux/summary/foldWorkflows";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";

const NOW = 1_800_000_000_000;
const summaries = (stage: "running" | "finished") => createWorkflowAdapter()(workflowFixture(stage, NOW), "s1");
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("the adapter derives each phase's state and counts, what runs next, and the model's name", () => {
  const [workflow] = summaries("running");
  expect(workflow!.description).toStartWith("Demo: 3 agents brainstorm names");
  expect(workflow!.phases.map((phase) => phase.state)).toEqual(["completed", "running", "pending"]);
  expect(tally(workflow!.agents)).toEqual({ running: 1, queued: 2, done: 3, failed: 0, total: 6 });
  expect(upNext(workflow!).map((phase) => phase.name)).toEqual(["Judge"]);
  expect(workflow!.agents[0]!.model).toBe("claude-opus-5-5");
  expect(phaseState([])).toBe("pending");
  expect([
    modelName("claude-opus-5-5"),
    modelName("sonnet"),
    modelName("claude-haiku-4-5-20251001"),
    modelName("gpt-6"),
  ]).toEqual(["Opus 5.5", "Sonnet", "Haiku 4.5", "Gpt 6"]);
});

test("a running workflow shows its counts, tokens, description, phases, the open running phase and Up next", () => {
  const html = renderToStaticMarkup(<WorkflowTasks workflows={summaries("running")} onStop={async () => undefined} />);
  const shown = text(html);
  // One group: the section's head counts it, so no group head.
  expect(html).not.toContain("acpmux-workflow-tasks__group");
  expect(shown).toContain("demo-name-tournament");
  expect(shown).toContain("1 running · 2 queued · 3 done · 185k tokens");
  expect(shown).toContain("Demo: 3 agents brainstorm names");
  expect(shown).toContain("Brainstorm 3 done");
  // The phase with a running agent is open: its model once, its agents with how long or Queued.
  expect(shown).toContain("Critique 1 running · 2 queued Model: Opus 5.5 punchy");
  expect(shown).toContain("playful Queued descriptive Queued");
  // Judge has no agent yet: not a phase row, but Up next.
  expect(html.match(/class="acpmux-workflow-phase"/g)?.length).toBe(2);
  expect(shown).toContain("Up next: Judge");
  expect(html.match(/acpmux-workflow-dot"/g)?.length).toBe(6);
  expect(html).toContain('aria-label="Stop demo-name-tournament"');
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
  expect(shown()).toContain("Judge 1/1 Model: Opus 5.5 judge 41s");
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
