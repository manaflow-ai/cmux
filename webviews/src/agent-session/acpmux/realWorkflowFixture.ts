// l10n-allow-file: a scrubbed replay of a real Claude workflow, used by tests and the gallery.
// The source recording was captured from acpmux's session/update stream. It keeps the event
// sequence and workflow progress deltas while replacing session IDs, paths, and run IDs with
// neutral fixture values.
import { SubagentFold, type Subagent } from "./subagents/subagentFold";

export type WorkflowReplayEvent = {
  at: number;
  update: Record<string, unknown>;
  subagents: Record<string, unknown>[];
};

const WORKFLOW = "workflow-session/tool-workflow";
const RUN = "workflow-run-1";
const MODEL = "claude-opus-5-5";
const SCRIPT = "/workspace/workflows/count-files.js";

const agent = (index: number, label: string, phase: string, phaseIndex: number, fields: Record<string, unknown> = {}) => ({
  index,
  label,
  phase,
  phaseIndex,
  model: MODEL,
  ...fields,
});

const phases = [
  { index: 1, title: "Count" },
  { index: 2, title: "Report" },
];

const workflow = (fields: Record<string, unknown>) => ({
  id: WORKFLOW,
  parent: null,
  kind: "workflow",
  name: "count-files-fixture",
  ...fields,
});

/// The real event sequence, with timestamps normalized to the workflow's first event.
export const REAL_WORKFLOW_RECORDING: readonly WorkflowReplayEvent[] = [
  {
    at: 0,
    update: { sessionUpdate: "subagent_spawned", subagentSessionId: WORKFLOW },
    subagents: [workflow({ state: "running", task: "Workflow" })],
  },
  {
    at: 17,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      name: "count-files-fixture",
      runId: RUN,
      scriptPath: SCRIPT,
      task: "Two agents count files, then one reports the count",
    },
    subagents: [workflow({ state: "running", runId: RUN, scriptPath: SCRIPT, task: "Two agents count files, then one reports the count" })],
  },
  {
    at: 40,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      phases,
      action: "Two-phase file count",
      agents: { done: 0, started: 0 },
      tokens: 0,
      toolUses: 0,
      elapsedMs: 26,
    },
    subagents: [workflow({ state: "running", runId: RUN, phases, action: "Two-phase file count", agents: { done: 0, started: 0 }, tokens: 0, toolUses: 0, elapsedMs: 26 })],
  },
  {
    at: 111,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Count: count-a",
      agents: { done: 0, queued: 1, started: 1 },
      workflowAgents: [
        agent(1, "count-a", "Count", 1, {
          agentId: "workflow-agent-1",
          state: "running",
          prompt: "Count regular files directly in the current working directory.",
          queuedAt: 548,
          startedAt: 564,
          lastProgressAt: 565,
          attempt: 1,
        }),
        agent(2, "count-b", "Count", 1, {
          agentId: "workflow-agent-2",
          state: "queued",
          prompt: "Count regular files directly in the current working directory.",
          queuedAt: 548,
        }),
      ],
      elapsedMs: 66,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Count: count-a", agents: { done: 0, queued: 1, started: 1 }, elapsedMs: 66 })],
  },
  {
    at: 1954,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Count: count-b",
      agents: { done: 0, started: 2 },
      workflowAgents: [
        agent(2, "count-b", "Count", 1, {
          agentId: "workflow-agent-2",
          state: "running",
          startedAt: 564,
          queuedAt: 548,
          lastProgressAt: 1937,
          attempt: 1,
        }),
      ],
      elapsedMs: 1940,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Count: count-b", agents: { done: 0, started: 2 }, elapsedMs: 1940 })],
  },
  {
    at: 2976,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Count: count-a",
      agents: { done: 0, started: 2 },
      tokens: 27557,
      toolUses: 1,
      elapsedMs: 2962,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Count: count-a", agents: { done: 0, started: 2 }, tokens: 27557, toolUses: 1, elapsedMs: 2962 })],
  },
  {
    at: 4605,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Count: count-b",
      agents: { done: 0, started: 2 },
      tokens: 55096,
      toolUses: 2,
      elapsedMs: 4591,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Count: count-b", agents: { done: 0, started: 2 }, tokens: 55096, toolUses: 2, elapsedMs: 4591 })],
  },
  {
    at: 5123,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Count: count-a",
      agents: { done: 1, started: 2 },
      tokens: 55592,
      toolUses: 3,
      workflowAgents: [
        agent(1, "count-a", "Count", 1, {
          agentId: "workflow-agent-1",
          state: "completed",
          result: '{"count":2}',
          elapsedMs: 5054,
          tokens: 28053,
          toolUses: 2,
          lastProgressAt: 5119,
        }),
        agent(2, "count-b", "Count", 1, {
          agentId: "workflow-agent-2",
          state: "running",
          action: "Count files",
          tokens: 27539,
          toolUses: 1,
          lastProgressAt: 4589,
        }),
      ],
      elapsedMs: 5108,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Count: count-a", agents: { done: 1, started: 2 }, tokens: 55592, toolUses: 3, elapsedMs: 5108 })],
  },
  {
    at: 6589,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Report: report",
      agents: { done: 2, started: 3 },
      tokens: 56126,
      toolUses: 4,
      workflowAgents: [
        agent(2, "count-b", "Count", 1, {
          agentId: "workflow-agent-2",
          state: "completed",
          result: '{"count":2}',
          elapsedMs: 4640,
          tokens: 28073,
          toolUses: 2,
          lastProgressAt: 6577,
        }),
        agent(3, "report", "Report", 2, {
          agentId: "workflow-agent-3",
          state: "running",
          prompt: "Recount the regular files and report whether both counts agree.",
          queuedAt: 6578,
          startedAt: 6579,
          lastProgressAt: 6579,
          attempt: 1,
        }),
      ],
      elapsedMs: 6575,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Report: report", agents: { done: 2, started: 3 }, tokens: 56126, toolUses: 4, elapsedMs: 6575 })],
  },
  {
    at: 8760,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Report: report",
      agents: { done: 2, started: 3 },
      tokens: 83572,
      toolUses: 5,
      elapsedMs: 8745,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Report: report", agents: { done: 2, started: 3 }, tokens: 83572, toolUses: 5, elapsedMs: 8745 })],
  },
  {
    at: 10700,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Report: report",
      agents: { done: 2, started: 3 },
      tokens: 84080,
      toolUses: 5,
      elapsedMs: 10685,
    },
    subagents: [workflow({ state: "running", runId: RUN, action: "Report: report", agents: { done: 2, started: 3 }, tokens: 84080, toolUses: 5, elapsedMs: 10685 })],
  },
  {
    at: 10780,
    update: {
      sessionUpdate: "subagent_progress",
      subagentSessionId: WORKFLOW,
      action: "Report: report",
      agents: { done: 3, started: 3 },
      tokens: 84080,
      toolUses: 5,
      elapsedMs: 10761,
      phases,
      runId: RUN,
      scriptPath: SCRIPT,
      workflowAgents: [
        agent(1, "count-a", "Count", 1, {
          agentId: "workflow-agent-1",
          state: "completed",
          result: '{"count":2}',
          elapsedMs: 5054,
          tokens: 28053,
          toolUses: 2,
          startedAt: 564,
          queuedAt: 548,
          lastProgressAt: 5119,
        }),
        agent(2, "count-b", "Count", 1, {
          agentId: "workflow-agent-2",
          state: "completed",
          result: '{"count":2}',
          elapsedMs: 4640,
          tokens: 28073,
          toolUses: 2,
          startedAt: 564,
          queuedAt: 548,
          lastProgressAt: 6577,
        }),
        agent(3, "report", "Report", 2, {
          agentId: "workflow-agent-3",
          state: "completed",
          result: "The recount found 2 regular files, matching both earlier counts.",
          elapsedMs: 4195,
          tokens: 27954,
          toolUses: 1,
          startedAt: 6579,
          queuedAt: 6578,
          lastProgressAt: 10772,
        }),
      ],
      workflowAgentsFull: true,
    },
    subagents: [workflow({ state: "running", runId: RUN, scriptPath: SCRIPT, phases, agents: { done: 3, started: 3 }, tokens: 84080, toolUses: 5, elapsedMs: 10753 })],
  },
  {
    at: 10780,
    update: { sessionUpdate: "subagent_state_update", subagentSessionId: WORKFLOW, state: "completed" },
    subagents: [{ id: WORKFLOW, parent: null, state: "completed" }],
  },
];

/// Feed the captured records through the production SubagentFold, preserving event order and timing.
export function realWorkflowFixture(now = Date.now()): Subagent[] {
  const fold = new SubagentFold();
  const start = now - REAL_WORKFLOW_RECORDING.at(-1)!.at;
  REAL_WORKFLOW_RECORDING.forEach((record, index) => {
    // acpmux mirrors workflow progress fields in the `_meta.acpmux.subagents` snapshot that the
    // pane consumes. Keep that wire shape here instead of feeding the fold a summary shortcut.
    const mirrored = [
      "name",
      "runId",
      "scriptPath",
      "task",
      "action",
      "agents",
      "tokens",
      "toolUses",
      "elapsedMs",
      "phases",
      "workflowAgents",
      "workflowAgentsFull",
    ];
    const shared = Object.fromEntries(
      mirrored.flatMap((key) => (record.update[key] === undefined ? [] : [[key, record.update[key]]])),
    );
    const subagents = record.subagents.map((change) => ({ ...shared, ...change }));
    const msg = { method: "session/update", params: { update: record.update, _meta: { acpmux: { subagents } } } };
    fold.reduce({ seq: index + 1, at: start + record.at, msg }, record.update);
  });
  return fold.all();
}
