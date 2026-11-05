// l10n-allow-file: fixture workflow, phase, agent and command names in assertions, not shipped UI.
// What the workflow card and Session Info's Background tasks show of a Claude workflow
// (summary/workflowView.ts), from Leo's 2026-11-05 list: running and finished apart, a phase as one
// row with its count, "Up next" for the phase no agent reached, an agent's words rather than its
// shell command, its output rendered rather than raw JSON, every running phase on the card with a
// count that is not a total while agents may still spawn, one clock, the model only where it
// differs, and the shell tasks a workflow's agents started under those agents. The data is a
// workflow's events fed through the real fold (summary/workflowFixture.ts `parallel`).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { backgroundCommands } from "../src/agent-session/acpmux/session-info/processes";
import { WorkflowTasks } from "../src/agent-session/acpmux/session-info/WorkflowTasks";
import { createWorkflowAdapter } from "../src/agent-session/acpmux/summary/foldWorkflows";
import { WorkflowCard } from "../src/agent-session/acpmux/summary/WorkflowCard";
import { parallelWorkflowProcesses, workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";
import {
  agentLine,
  agentModel,
  attributeCommands,
  cardCount,
  cardLine,
  listedPhases,
  looksLikeCommand,
  outputMarkdown,
  phaseCount,
  runningPhases,
  splitAgents,
  upNext,
  workflowModel,
} from "../src/agent-session/acpmux/summary/workflowView";
import type { WorkflowAgent } from "../src/agent-session/acpmux/summary/workflow";
import { backgroundGroups } from "../src/agent-session/acpmux/backgroundTasks/backgroundTasks";
import { SUBAGENTS, type Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const NOW = 1_800_000_000_000;
const parallel = () => createWorkflowAdapter()(workflowFixture("parallel", NOW), "s1")[0]!;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const byName = (name: string) => parallel().agents.find((agent) => agent.name === name)!;

test("running and finished agents are apart, the finished the latest first", () => {
  const { running, finished } = splitAgents(parallel().agents);
  expect(running.map((agent) => agent.name)).toEqual([
    "latency:measure",
    "latency:code-path",
    "latency:prior-art",
    "swarm:ours",
    "swarm:codebases",
  ]);
  expect(finished.map((agent) => agent.name)).toEqual(["swarm:history", "swarm:products"]);
});

test("two phases run at once; a phase counts done of its agents; the first unreached phase is up next", () => {
  const workflow = parallel();
  expect(runningPhases(workflow).map((phase) => phase.name)).toEqual(["Latency", "Swarm research"]);
  expect(listedPhases(workflow).map((phase) => [phase.name, phaseCount(workflow, phase)])).toEqual([
    ["Latency", { done: 0, total: 3 }],
    ["Swarm research", { done: 2, total: 4 }],
  ]);
  // Every phase no agent reached is up next, in order.
  expect(upNext(workflow).map((phase) => phase.name)).toEqual(["Latency plan", "Swarm synthesis"]);
  // Once it ended nothing is next, and every phase is listed.
  const ended = { ...workflow, state: "completed" as const };
  expect(upNext(ended)).toEqual([]);
  expect(listedPhases(ended).length).toBe(4);
});

test("the card counts done and running while agents may still spawn, and done of total once they cannot", () => {
  const workflow = parallel();
  expect(cardCount(workflow)).toMatchObject({ kind: "progress", done: 2, running: 5 });
  const [finished] = createWorkflowAdapter()(workflowFixture("finished", NOW), "s1");
  expect(cardCount(finished!)).toEqual({ kind: "total", done: 7, total: 7 });
});

test("an agent says what it does in words, never its last shell command or JSON", () => {
  expect(looksLikeCommand("f=~/.claude/projects/-Users-me/s1.jsonl; jq -r .timestamp $f")).toBe(true);
  expect(looksLikeCommand("cd ~/Projects/cmux && gh pr list")).toBe(true);
  expect(looksLikeCommand("timeout 30 acpmux --json ls")).toBe(true);
  expect(looksLikeCommand("Compare the strongest names against the brief")).toBe(false);
  // Sentences with a semicolon or a comparison are words.
  expect(looksLikeCommand("I checked the pool; two runners are idle")).toBe(false);
  expect(looksLikeCommand("p95 > 200ms on the first reply")).toBe(false);
  expect(looksLikeCommand("cd ~/x; git status")).toBe(true);
  // Only paired emphasis is folded: identifiers keep their underscores.
  const said = (lastMessage: string) => agentLine({ id: "x", name: "x", state: "running", lastMessage });
  expect(said("Reading workflow_agent_id in **processes.ts**")).toBe("Reading workflow_agent_id in processes.ts");
  // A message that opens with a link is words, not JSON.
  expect(said("[#33406](https://github.com/x/y/pull/33406) merged")).toBe(
    "[#33406](https://github.com/x/y/pull/33406) merged",
  );
  // Its prompt when its step is a command; its message when it has one in words.
  expect(agentLine(byName("latency:measure"))).toBe(
    "Measure where the first reply's time goes, from the click to the first token",
  );
  expect(agentLine(byName("latency:code-path"))).toBe(
    "Tracing the new-chat path from the composer to acpmux's session/new",
  );
  expect(agentLine(byName("swarm:ours"))).toBe("Describe how our own lanes and coordinators split and hand off work");
  // A finished row says nothing on its line: it opens to its output.
  expect(agentLine(byName("swarm:products"))).toBeUndefined();
  // A failed one says why.
  expect(agentLine({ ...byName("swarm:ours"), state: "failed", error: "503: no capacity" })).toBe("503: no capacity");
});

test("a finished agent's output is its prose, rendered, even from a JSON result cut short", () => {
  expect(outputMarkdown(byName("swarm:products"))).toBe(
    "I compared six agent products. **Three** run a planner that hands each worker one file set; the rest let workers claim tasks from a shared board.",
  );
  // Claude sends 240 characters of a result: the prose field up to the cut.
  expect(outputMarkdown(byName("swarm:history"))).toStartWith(
    "Across about forty years of multi-agent systems work, the designs that lasted",
  );
  expect(outputMarkdown(byName("swarm:history"))).toEndWith("…");
  const agent = (result: string): WorkflowAgent => ({ id: "x", name: "x", state: "completed", result });
  expect(outputMarkdown(agent('{"files":3,"ok":true}'))).toBe("- **files**: 3\n- **ok**: true");
  expect(outputMarkdown(agent("Plain **words**"))).toBe("Plain **words**");
  expect(outputMarkdown(agent("[x] Checked the pool\n[x] Measured"))).toBe("[x] Checked the pool\n[x] Measured");
  expect(outputMarkdown({ id: "x", name: "x", state: "completed" })).toBeUndefined();
});

test("the model shows once for the workflow and on an agent only where it differs", () => {
  const workflow = parallel();
  const model = workflowModel(workflow.agents);
  expect(model).toBe("claude-opus-5-5");
  expect(agentModel(byName("latency:measure"), model)).toBeUndefined();
  expect(agentModel(byName("swarm:ours"), model)).toBe("claude-sonnet-5-5");
});

test("commands a workflow's agents started are those agents', the rest the chat's own", () => {
  const workflow = parallel();
  const commands = backgroundCommands(parallelWorkflowProcesses(NOW), [], true);
  const { own, workflows } = attributeCommands(commands, [workflow]);
  expect(own.map((command) => command.description)).toEqual(["Watch the agent pane tests"]);
  const of = (name: string) => workflows.byAgent.get(byName(name).id)?.map((command) => command.id);
  expect(of("latency:prior-art")).toEqual(["acp-1/bg-fetch"]);
  expect(of("latency:code-path")).toEqual(["acp-1/bg-checkout"]);
  expect(of("latency:measure")).toEqual(["acp-1/bg-bench"]);
  // Known only by the workflow (no agent id from the registry): under the workflow itself.
  const unnamed = commands.map((command) => ({ ...command, workflowAgent: undefined }));
  const byWorkflow = attributeCommands(unnamed, [workflow]).workflows.byWorkflow.get(workflow.id);
  expect(byWorkflow?.length).toBe(3);
});

test("Session Info lists phases closed with their counts, Up next, words, nested commands and finished output", async () => {
  const workflow = parallel();
  const commands = attributeCommands(backgroundCommands(parallelWorkflowProcesses(NOW), [], true), [workflow]);
  const html = renderToStaticMarkup(
    <WorkflowTasks workflows={[workflow]} commands={commands.workflows} onStop={async () => undefined} />,
  );
  const shown = text(html);
  expect(shown).toContain("5 running · 2 done · 757k tokens · Opus 5.5");
  expect(shown).toContain("Latency 0/3");
  expect(shown).toContain("Swarm research 2/4");
  expect(shown).toContain("Up next: Latency plan, Swarm synthesis");
  // Phases are closed until opened, except one whose agents started a command that still runs:
  // Latency opens on its own, so that command's time and Stop stay in sight.
  expect(html.match(/acpmux-workflow-phase__agents/g)?.length).toBe(1);
  expect(shown).toContain("git fetch origin feat-cmux-next");
  // The ended agents are under "2 finished", out of the running lists.
  expect(shown).toContain("2 finished swarm:history");
  expect(shown).not.toContain("Model: Opus 5.5");
  expect(shown).not.toContain('{"summary"');

  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  install(dom);
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () =>
    root!.render(<WorkflowTasks workflows={[workflow]} commands={commands.workflows} onStop={async () => undefined} />),
  );
  const heads = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-workflow-phase__head")];
  await act(async () => heads[1]!.click());
  const rendered = text(container.innerHTML);
  expect(rendered).toContain("latency:prior-art Find earlier PRs and issues about first-reply latency");
  // Named without the `cd` that only sets the stage (processes.ts `commandLabel`).
  expect(rendered).toContain("git fetch origin feat-cmux-next");
  expect(rendered).toContain("Find freshest cmux checkout");
  expect(rendered).toContain("swarm:ours Model: Sonnet 5.5");
  expect(rendered).not.toContain("f=~/.claude");
  expect(rendered).not.toContain("timeout 30 acpmux");
  // Opening swarm:products shows its output, the JSON's prose rendered as Markdown.
  const products = [...container.querySelectorAll(".acpmux-workflow-finished .acpmux-workflow-agent")].find((row) =>
    row.textContent?.includes("swarm:products"),
  )!;
  await act(async () => products.querySelector<HTMLButtonElement>(".acpmux-workflow-agent__disclosure")!.click());
  const output = products.querySelector(".acpmux-workflow-agent__output")!;
  expect(output.querySelector("strong")?.textContent).toBe("Three");
  expect(output.textContent).not.toContain("{");
});

test("the card names every running phase, counts done and running, shows one clock and the workflow's model", () => {
  const [node] = workflowFixture("parallel", NOW).filter((each) => each.kind === "workflow");
  const html = renderToStaticMarkup(
    <WorkflowCard node={{ ...node!, endedAt: node!.startedAt + 25 * 60_000 + 14_000 }} />,
  );
  const shown = text(html);
  expect(shown).toContain("Running 2 done · 5 running 25m 14s 757.3K tokens");
  // Its last row names both running phases, then the workflow's model.
  expect(shown).toContain("Latency, Swarm research Opus 5.5");
  // Its latest line names the agent it is from: the one most recently active.
  expect(shown).toContain("latency:code-path Tracing the new-chat path");
  expect(shown).not.toContain("2/7");
  // One clock: the workflow's; no agent's own time beside it.
  expect(shown.match(/\d+m \d+s/g)).toEqual(["25m 14s"]);
  expect(shown).toContain("Opus 5.5");
  expect(shown).not.toContain("claude-opus-5-5");
  // Its latest line is in words.
  expect(cardLine(createWorkflowAdapter()([node!], "s1")[0]!)?.line).not.toMatch(/^(cd|f=|timeout)\b/);
});

test("the Background tasks panel lists a subagent's commands under that subagent, not the chat", () => {
  const agent: Subagent = {
    id: "acp-1/toolu_a",
    parent: null,
    name: "Explore",
    task: "Read the reconnect code",
    kind: "Explore",
    state: "running",
    startedAt: NOW - 60_000,
  };
  const rows: AcpmuxRow[] = [{ id: "g", version: 1, at: NOW - 60_000, kind: SUBAGENTS, subagents: [agent] }];
  const commands = backgroundCommands(
    [
      {
        id: "acp-1/bg-1",
        toolCallId: "toolu_cmd",
        command: "bun test --watch",
        state: "running",
        subagent: agent.id,
        startedAt: NOW - 30_000,
      },
      { id: "acp-1/bg-2", toolCallId: "toolu_own", command: "make watch", state: "running", startedAt: NOW - 10_000 },
    ],
    [],
    true,
  );
  const groups = backgroundGroups({ rows, commands, sessions: [], chatName: "Chat" });
  const explore = groups.find((group) => group.id === `agent:${agent.id}`)!;
  expect(explore.running.map((task) => task.id)).toEqual(["acp-1/bg-1"]);
  expect(groups.find((group) => group.id === "commands")!.running.map((task) => task.id)).toEqual(["acp-1/bg-2"]);
});

test("the Background tasks panel nests a workflow agent's command under that agent", () => {
  const nodes = workflowFixture("parallel", NOW);
  const rows: AcpmuxRow[] = [{ id: "g", version: 1, at: NOW - 60_000, kind: SUBAGENTS, subagents: nodes }];
  const commands = backgroundCommands(parallelWorkflowProcesses(NOW), [], true);
  const groups = backgroundGroups({ rows, commands, sessions: [], chatName: "Chat", sessionId: "s1" });
  const workflow = groups.find((group) => group.id === `agent:${parallel().id}`)!;
  const tasks = [...workflow.running, ...workflow.finished];
  const parentOf = (id: string) => tasks.find((task) => task.id === parentId(id))?.title;
  const parentId = (id: string) => tasks.find((task) => task.id === id)?.parent;
  expect(parentOf("acp-1/bg-fetch")).toBe("latency:prior-art");
  expect(parentOf("acp-1/bg-checkout")).toBe("latency:code-path");
  expect(parentOf("acp-1/bg-bench")).toBe("latency:measure");
  expect(groups.find((group) => group.id === "commands")!.running.map((task) => task.id)).toEqual(["acp-1/bg-own"]);
});

test("a command an agent started stays in sight with its Stop after the agent finishes", () => {
  const workflow = parallel();
  const products = workflow.agents.find((agent) => agent.name === "swarm:products")!;
  const command = {
    ...backgroundCommands(parallelWorkflowProcesses(NOW), [], true).find((each) => each.id === "acp-1/bg-fetch")!,
    workflowAgent: products.agentId,
  };
  const { workflows } = attributeCommands([command], [workflow]);
  const html = renderToStaticMarkup(
    <WorkflowTasks workflows={[workflow]} commands={workflows} onStop={async () => undefined} />,
  );
  // Not behind the output disclosure: the finished row shows it, closed.
  expect(text(html)).toContain("git fetch origin feat-cmux-next");
  expect(html).not.toContain("acpmux-workflow-agent__output");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const install = (window: JSDOM) => {
  for (const [key, value] of Object.entries({
    window: window.window,
    document: window.window.document,
    HTMLElement: window.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
};
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});
