// l10n-allow-file: fixture workflow, phase and agent names (sample data for tests and the gallery), not shipped UI.
//
// A Claude workflow as acpmux sends it (`workflow-agents-v1`, claude_stdio/workflows.rs), fed
// through the real subagent fold: the gallery and the tests draw from what the fold keeps, never
// from hand-made summaries. Three phases (Brainstorm, Critique, Judge), seven agents.
import type { SessionInfoProcess } from "../session-info/processes";
import { SubagentFold, type Subagent } from "../subagents/subagentFold";

export type WorkflowFixtureStage = "running" | "finished" | "parallel";

const NODE = "acp-1/toolu_wf";
const MODEL = "claude-opus-5-5";
const PHASES = [
  { index: 1, title: "Brainstorm" },
  { index: 2, title: "Critique" },
  { index: 3, title: "Judge" },
];

const agent = (index: number, phaseIndex: number, label: string, fields: Record<string, unknown>) => ({
  index,
  label,
  phaseIndex,
  phase: PHASES[phaseIndex - 1]!.title,
  agentId: `a${index}`,
  model: MODEL,
  ...fields,
});

/// The workflow's subagent nodes after the events of `stage`, timed so that `now` is 13 seconds
/// into the run (running), 40 seconds after it ended (finished) or 25 minutes 18 seconds in (parallel).
export function workflowFixture(stage: WorkflowFixtureStage, now = Date.now()): Subagent[] {
  const fold = new SubagentFold();
  const start = stage === "running" ? now - 13_000 : stage === "parallel" ? now - 25 * 60_000 - 18_000 : now - 120_000;
  let seq = 0;
  const feed = (offsetMs: number, update: Record<string, unknown>, subagents: Record<string, unknown>[]) => {
    seq += 1;
    const msg = { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } };
    fold.reduce({ seq, at: start + offsetMs, msg }, update);
  };
  const progress = (offsetMs: number, fields: Record<string, unknown>) =>
    feed(offsetMs, { sessionUpdate: "subagent_progress" }, [{ id: NODE, parent: null, state: "running", ...fields }]);
  feed(0, { sessionUpdate: "subagent_spawned" }, [
    { id: NODE, parent: null, name: "Workflow", kind: "workflow", state: "running" },
  ]);
  // The launch: its name, run id and what it does.
  progress(400, {
    name: "demo-name-tournament",
    runId: "wf_7c2e91",
    scriptPath: "/home/me/.claude/projects/-w/s1/workflows/scripts/demo-name-tournament-wf_7c2e91.js",
    task: "Demo: 3 agents brainstorm names from different angles, each gets critiqued, then a judge picks the winner",
  });
  const brainstorm = [
    agent(1, 1, "punchy", { state: "completed", startedAt: start + 1_000, elapsedMs: 7_000, tokens: 61_200 }),
    agent(2, 1, "descriptive", { state: "completed", startedAt: start + 1_000, elapsedMs: 3_000, tokens: 58_400 }),
    agent(3, 1, "playful", { state: "completed", startedAt: start + 1_000, elapsedMs: 3_000, tokens: 65_500 }),
  ];
  if (stage === "parallel") return parallelRun(fold, progress, start);
  if (stage === "running") {
    progress(12_000, {
      phases: PHASES,
      workflowAgents: [
        ...brainstorm,
        agent(4, 2, "punchy", {
          state: "running",
          startedAt: start + 8_500,
          tokens: 12_000,
          action: "Compare the strongest names against the brief",
          result: "The latest shortlist favors names that read clearly at a glance.",
        }),
        agent(5, 2, "playful", { state: "queued", queuedAt: start + 8_500 }),
        agent(6, 2, "descriptive", { state: "queued", queuedAt: start + 8_500 }),
      ],
      agents: { done: 3, started: 4, queued: 2 },
      tokens: 185_100,
      action: "Critique: punchy",
    });
    return fold.all();
  }
  const critique = [4, 5, 6].map((index, i) =>
    agent(index, 2, ["punchy", "playful", "descriptive"][i]!, {
      state: "completed",
      startedAt: start + 8_500 + i * 2_000,
      elapsedMs: 9_000 + i * 1_500,
      tokens: 52_000 + i * 4_100,
    }),
  );
  const judge = agent(7, 3, "judge", {
    state: "completed",
    startedAt: start + 30_000,
    elapsedMs: 41_000,
    tokens: 63_600,
  });
  // The run's end: its final usage and every agent whole, then its state.
  progress(80_000, {
    phases: PHASES,
    workflowAgents: [...brainstorm, ...critique, judge],
    workflowAgentsFull: true,
    agents: { done: 7, started: 7 },
    tokens: 432_300,
  });
  feed(80_000, { sessionUpdate: "subagent_state_update" }, [{ id: NODE, state: "completed" }]);
  return fold.all();
}

/// The `parallel` stage's phases: two tracks, each a research phase then a phase no agent has reached.
const PARALLEL_PHASES = [
  { index: 1, title: "Latency" },
  { index: 2, title: "Latency plan" },
  { index: 3, title: "Swarm research" },
  { index: 4, title: "Swarm synthesis" },
];

/// A workflow two phases of which run at once (Latency and Swarm research), 25 minutes in, as in Leo's
/// screenshot of 2026-11-05: five agents running, each last seen running a shell command; two of
/// Swarm research finished with structured (JSON) results; Latency plan and Swarm synthesis not
/// reached yet. One agent runs on another model than the rest.
function parallelRun(
  fold: SubagentFold,
  progress: (offsetMs: number, fields: Record<string, unknown>) => void,
  start: number,
): Subagent[] {
  const minute = 60_000;
  const at = (index: number, phaseIndex: number, label: string, fields: Record<string, unknown>) => ({
    index,
    label,
    phaseIndex,
    phase: PARALLEL_PHASES[phaseIndex - 1]!.title,
    agentId: `p${index}`,
    model: MODEL,
    ...fields,
  });
  progress(400, {
    name: "first-chat-latency-and-swarm-research",
    runId: "wf_5a07b4",
    task: "Two tracks: find why a new chat takes 20-30s to answer, and survey how other agent swarms coordinate",
  });
  progress(25 * minute, {
    phases: PARALLEL_PHASES,
    workflowAgents: [
      at(1, 1, "latency:measure", {
        state: "running",
        startedAt: start + 10_000,
        tokens: 98_000,
        action: "f=~/.claude/projects/-Users-me-Projects/s1.jsonl; jq -r .timestamp $f | head",
        prompt: "Measure where the first reply's time goes, from the click to the first token",
      }),
      at(2, 1, "latency:code-path", {
        state: "running",
        startedAt: start + 11_000,
        lastProgressAt: start + 25 * minute + 10_000,
        tokens: 121_000,
        action: "cd /Users/me/Projects/cmux && rg -n startSession webviews/src",
        lastMessage: "Tracing the new-chat path from the composer to acpmux's session/new",
      }),
      at(3, 1, "latency:prior-art", {
        state: "running",
        startedAt: start + 11_000,
        tokens: 87_000,
        action: "cd ~/Projects/cmux && gh pr list --search latency",
        prompt: "Find earlier PRs and issues about first-reply latency",
      }),
      at(4, 3, "swarm:ours", {
        state: "running",
        startedAt: start + 12_000,
        tokens: 140_000,
        model: "claude-sonnet-5-5",
        action: "timeout 30 acpmux --json ls",
        prompt: "Describe how our own lanes and coordinators split and hand off work",
      }),
      at(5, 3, "swarm:products", {
        state: "completed",
        startedAt: start + 12_000,
        elapsedMs: 18 * minute + 13_000,
        tokens: 156_000,
        result:
          '{"summary":"I compared six agent products. **Three** run a planner that hands each worker one file set; the rest let workers claim tasks from a shared board.","sources":6}',
      }),
      at(6, 3, "swarm:codebases", {
        state: "running",
        startedAt: start + 12_000,
        tokens: 77_000,
        action: "cd ~/Projects/swarm-research-scratch/oss && git log --oneline | head -50",
        prompt: "Read three open-source swarm frameworks and note how they schedule agents",
      }),
      at(7, 3, "swarm:history", {
        state: "completed",
        startedAt: start + 12_000,
        elapsedMs: 19 * minute + 15_000,
        tokens: 78_000,
        result:
          '{"summary":"Across about forty years of multi-agent systems work, the designs that lasted kept one owner per task and a shared ledger of who holds what. Contract nets and blackboards are the',
      }),
    ],
    agents: { done: 2, started: 7 },
    tokens: 757_300,
    action: "Latency: latency:measure",
  });
  return fold.all();
}

/// The `parallel` stage's background commands as the registry lists them: what its agents left
/// running in the background, attributed (`subagentSessionId` the workflow's, `workflowAgentId` the
/// agent's).
export function parallelWorkflowProcesses(now = Date.now()): SessionInfoProcess[] {
  return [
    {
      id: "acp-1/bg-fetch",
      toolCallId: "toolu_bg_fetch",
      command: "cd ~/Projects/cmux; git fetch origin feat-cmux-next && git log -1 origin/feat-cmux-next",
      state: "running",
      subagent: NODE,
      workflowAgent: "p3",
      startedAt: now - 4 * 60_000 - 9_000,
    },
    {
      id: "acp-1/bg-checkout",
      toolCallId: "toolu_bg_checkout",
      command: "ls -td ~/Projects/checkouts/cmux/* | head -1",
      description: "Find freshest cmux checkout",
      state: "running",
      subagent: NODE,
      workflowAgent: "p2",
      startedAt: now - 17 * 60_000 - 33_000,
    },
    {
      id: "acp-1/bg-bench",
      toolCallId: "toolu_bg_bench",
      command: "bun run bench:first-chat --runs 5",
      description: "Bench the first reply five times",
      state: "exited",
      subagent: NODE,
      workflowAgent: "p1",
      startedAt: now - 9 * 60_000,
      endedAt: now - 6 * 60_000,
    },
    {
      id: "acp-1/bg-own",
      toolCallId: "toolu_bg_own",
      command: "bun test --watch webviews/test",
      description: "Watch the agent pane tests",
      state: "running",
      startedAt: now - 2 * 60_000,
    },
  ];
}
