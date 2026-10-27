// l10n-allow-file: fixture workflow, phase and agent names (sample data for tests and the gallery), not shipped UI.
//
// A Claude workflow as acpmux sends it (`workflow-agents-v1`, claude_stdio/workflows.rs), fed
// through the real subagent fold: the gallery and the tests draw from what the fold keeps, never
// from hand-made summaries. Three phases (Brainstorm, Critique, Judge), seven agents.
import { SubagentFold, type Subagent } from "../subagents/subagentFold";

export type WorkflowFixtureStage = "running" | "finished";

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
/// into the run (running) or 40 seconds after it ended (finished).
export function workflowFixture(stage: WorkflowFixtureStage, now = Date.now()): Subagent[] {
  const fold = new SubagentFold();
  const start = stage === "running" ? now - 13_000 : now - 120_000;
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
  if (stage === "running") {
    progress(12_000, {
      phases: PHASES,
      workflowAgents: [
        ...brainstorm,
        agent(4, 2, "punchy", { state: "running", startedAt: start + 8_500, tokens: 12_000 }),
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
