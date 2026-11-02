// l10n-allow-file: a scrubbed replay of a real Claude workflow, used by tests and the gallery.
// Generated from acpmux's recording of a real Claude Code Workflow run (2 phases, 3 agents): every
// `session/update` the agent pane received for subagents, with its `update` and its
// `_meta.acpmux.subagents` exactly as sent. Only identifying values are replaced (session, tool-call,
// run and agent ids; paths become /workspace/...), and epoch times become milliseconds since the
// workflow's first event. Nothing is added, merged or carried forward between events.
import { SubagentFold, type Subagent } from "./subagents/subagentFold";

export type WorkflowReplayEvent = {
  at: number;
  update: Record<string, unknown>;
  subagents: Record<string, unknown>[];
};

/// Workflow agent fields that hold a time, recorded relative to the workflow's first event.
const AGENT_TIMES = new Set(["queuedAt", "startedAt", "lastProgressAt"]);

/// The real event sequence, with timestamps normalized to the workflow's first event.
export const REAL_WORKFLOW_RECORDING: readonly WorkflowReplayEvent[] = [
  {
    at: 0,
    update: {
      _meta: {
        claude: {
          subagentType: "workflow",
          toolUseId: "tool-workflow",
        },
      },
      background: true,
      capabilities: {},
      name: "Workflow",
      prompt: null,
      sessionUpdate: "subagent_spawned",
      subagentSessionId: "workflow-session/tool-workflow",
      task: "Workflow",
    },
    subagents: [
      {
        background: true,
        id: "workflow-session/tool-workflow",
        kind: "workflow",
        name: "Workflow",
        parent: null,
        state: "running",
        task: "Workflow",
        toolCallId: "tool-workflow",
      },
    ],
  },
  {
    at: 17,
    update: {
      name: "count-files-fixture",
      runId: "workflow-run-1",
      scriptPath: "/workspace/workflows/scripts/count-files-fixture-workflow-run-1.js",
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      task: "Tiny 2-phase fixture: two agents count files, one agent reports the combined count",
    },
    subagents: [
      {
        id: "workflow-session/tool-workflow",
        name: "count-files-fixture",
        parent: null,
        runId: "workflow-run-1",
        scriptPath: "/workspace/workflows/scripts/count-files-fixture-workflow-run-1.js",
        state: "running",
        task: "Tiny 2-phase fixture: two agents count files, one agent reports the combined count",
      },
    ],
  },
  {
    at: 40,
    update: {
      action: "Tiny 2-phase fixture: two agents count files, one agent reports the combined count",
      agents: {
        done: 0,
        started: 0,
      },
      elapsedMs: 26,
      phases: [
        {
          index: 1,
          title: "Count",
        },
        {
          index: 2,
          title: "Report",
        },
      ],
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 0,
      toolUses: 0,
    },
    subagents: [
      {
        action: "Tiny 2-phase fixture: two agents count files, one agent reports the combined count",
        agents: {
          done: 0,
          started: 0,
        },
        elapsedMs: 26,
        id: "workflow-session/tool-workflow",
        parent: null,
        phases: [
          {
            index: 1,
            title: "Count",
          },
          {
            index: 2,
            title: "Report",
          },
        ],
        state: "running",
        tokens: 0,
        toolUses: 0,
      },
    ],
  },
  {
    at: 111,
    update: {
      action: "Count: count-a",
      agents: {
        done: 0,
        queued: 1,
        started: 1,
      },
      elapsedMs: 66,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 0,
      toolUses: 0,
      workflowAgents: [
        {
          agentId: "workflow-agent-1",
          attempt: 1,
          index: 1,
          label: "count-a",
          lastProgressAt: 65,
          model: "claude-opus-5-5",
          phase: "Count",
          phaseIndex: 1,
          prompt:
            "Count the regular files (not directories) directly in the current working directory, non-recursive, including hidden files. Use one shell command such as `find . -maxdepth 1 -type f | wc -l`. Return the count.",
          queuedAt: 48,
          startedAt: 64,
          state: "running",
        },
        {
          index: 2,
          label: "count-b",
          lastProgressAt: 48,
          model: "claude-opus-5-5",
          phase: "Count",
          phaseIndex: 1,
          prompt:
            "Count the files directly in the current working directory (non-recursive, regular files only, hidden included) using `ls -A` and filtering out directories. Return the count.",
          queuedAt: 48,
          state: "queued",
        },
      ],
    },
    subagents: [
      {
        action: "Count: count-a",
        agents: {
          done: 0,
          queued: 1,
          started: 1,
        },
        elapsedMs: 66,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 0,
        toolUses: 0,
        workflowAgents: [
          {
            agentId: "workflow-agent-1",
            attempt: 1,
            index: 1,
            label: "count-a",
            lastProgressAt: 65,
            model: "claude-opus-5-5",
            phase: "Count",
            phaseIndex: 1,
            prompt:
              "Count the regular files (not directories) directly in the current working directory, non-recursive, including hidden files. Use one shell command such as `find . -maxdepth 1 -type f | wc -l`. Return the count.",
            queuedAt: 48,
            startedAt: 64,
            state: "running",
          },
          {
            index: 2,
            label: "count-b",
            lastProgressAt: 48,
            model: "claude-opus-5-5",
            phase: "Count",
            phaseIndex: 1,
            prompt:
              "Count the files directly in the current working directory (non-recursive, regular files only, hidden included) using `ls -A` and filtering out directories. Return the count.",
            queuedAt: 48,
            state: "queued",
          },
        ],
      },
    ],
  },
  {
    at: 1954,
    update: {
      action: "Count: count-b",
      agents: {
        done: 0,
        started: 2,
      },
      elapsedMs: 1940,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 0,
      toolUses: 0,
      workflowAgents: [
        {
          agentId: "workflow-agent-2",
          attempt: 1,
          index: 2,
          lastProgressAt: 1937,
          startedAt: 64,
          state: "running",
        },
      ],
    },
    subagents: [
      {
        action: "Count: count-b",
        agents: {
          done: 0,
          started: 2,
        },
        elapsedMs: 1940,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 0,
        toolUses: 0,
        workflowAgents: [
          {
            agentId: "workflow-agent-2",
            attempt: 1,
            index: 2,
            lastProgressAt: 1937,
            startedAt: 64,
            state: "running",
          },
        ],
      },
    ],
  },
  {
    at: 2976,
    update: {
      action: "Count: count-a",
      agents: {
        done: 0,
        started: 2,
      },
      elapsedMs: 2962,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 27557,
      toolUses: 1,
    },
    subagents: [
      {
        action: "Count: count-a",
        agents: {
          done: 0,
          started: 2,
        },
        elapsedMs: 2962,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 27557,
        toolUses: 1,
      },
    ],
  },
  {
    at: 4605,
    update: {
      action: "Count: count-b",
      agents: {
        done: 0,
        started: 2,
      },
      elapsedMs: 4591,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 55096,
      toolUses: 2,
    },
    subagents: [
      {
        action: "Count: count-b",
        agents: {
          done: 0,
          started: 2,
        },
        elapsedMs: 4591,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 55096,
        toolUses: 2,
      },
    ],
  },
  {
    at: 5123,
    update: {
      action: "Count: count-a",
      agents: {
        done: 1,
        started: 2,
      },
      elapsedMs: 5108,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 55592,
      toolUses: 3,
      workflowAgents: [
        {
          action: "StructuredOutput",
          elapsedMs: 5054,
          index: 1,
          lastProgressAt: 5119,
          result: '{"count":2}',
          state: "completed",
          tokens: 28053,
          toolUses: 2,
        },
        {
          action: 'ls -A | while IFS= read -r f; do [ -f "$f" ] && [ ! -L "$f"…',
          index: 2,
          lastProgressAt: 4589,
          tokens: 27539,
          toolUses: 1,
        },
      ],
    },
    subagents: [
      {
        action: "Count: count-a",
        agents: {
          done: 1,
          started: 2,
        },
        elapsedMs: 5108,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 55592,
        toolUses: 3,
        workflowAgents: [
          {
            action: "StructuredOutput",
            elapsedMs: 5054,
            index: 1,
            lastProgressAt: 5119,
            result: '{"count":2}',
            state: "completed",
            tokens: 28053,
            toolUses: 2,
          },
          {
            action: 'ls -A | while IFS= read -r f; do [ -f "$f" ] && [ ! -L "$f"…',
            index: 2,
            lastProgressAt: 4589,
            tokens: 27539,
            toolUses: 1,
          },
        ],
      },
    ],
  },
  {
    at: 6589,
    update: {
      action: "Report: report",
      agents: {
        done: 2,
        started: 3,
      },
      elapsedMs: 6575,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 56126,
      toolUses: 4,
      workflowAgents: [
        {
          action: "StructuredOutput",
          elapsedMs: 4640,
          index: 2,
          lastProgressAt: 6577,
          result: '{"count":2}',
          state: "completed",
          tokens: 28073,
          toolUses: 2,
        },
        {
          agentId: "workflow-agent-3",
          attempt: 1,
          index: 3,
          label: "report",
          lastProgressAt: 6579,
          model: "claude-opus-5-5",
          phase: "Report",
          phaseIndex: 2,
          prompt:
            "Two agents counted the regular files in the current folder: agent A got 2, agent B got 2. Recount once with `find . -maxdepth 1 -type f | wc -l` and report the final count in one short sentence, noting whether the counts agreed.",
          queuedAt: 6578,
          startedAt: 6579,
          state: "running",
        },
      ],
    },
    subagents: [
      {
        action: "Report: report",
        agents: {
          done: 2,
          started: 3,
        },
        elapsedMs: 6575,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 56126,
        toolUses: 4,
        workflowAgents: [
          {
            action: "StructuredOutput",
            elapsedMs: 4640,
            index: 2,
            lastProgressAt: 6577,
            result: '{"count":2}',
            state: "completed",
            tokens: 28073,
            toolUses: 2,
          },
          {
            agentId: "workflow-agent-3",
            attempt: 1,
            index: 3,
            label: "report",
            lastProgressAt: 6579,
            model: "claude-opus-5-5",
            phase: "Report",
            phaseIndex: 2,
            prompt:
              "Two agents counted the regular files in the current folder: agent A got 2, agent B got 2. Recount once with `find . -maxdepth 1 -type f | wc -l` and report the final count in one short sentence, noting whether the counts agreed.",
            queuedAt: 6578,
            startedAt: 6579,
            state: "running",
          },
        ],
      },
    ],
  },
  {
    at: 8760,
    update: {
      action: "Report: report",
      agents: {
        done: 2,
        started: 3,
      },
      elapsedMs: 8745,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 83572,
      toolUses: 5,
    },
    subagents: [
      {
        action: "Report: report",
        agents: {
          done: 2,
          started: 3,
        },
        elapsedMs: 8745,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 83572,
        toolUses: 5,
      },
    ],
  },
  {
    at: 10700,
    update: {
      action: "Report: report",
      agents: {
        done: 2,
        started: 3,
      },
      elapsedMs: 10685,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 84080,
      toolUses: 5,
    },
    subagents: [
      {
        action: "Report: report",
        agents: {
          done: 2,
          started: 3,
        },
        elapsedMs: 10685,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 84080,
        toolUses: 5,
      },
    ],
  },
  {
    at: 10780,
    update: {
      action: "Report: report",
      agents: {
        done: 3,
        started: 3,
      },
      elapsedMs: 10761,
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 84080,
      toolUses: 5,
      workflowAgents: [
        {
          action: "find . -maxdepth 1 -type f | wc -l",
          elapsedMs: 4195,
          index: 3,
          lastProgressAt: 10774,
          result: "The recount found 2 regular files, which matches the counts from agent A (2) and agent B (2).",
          state: "completed",
          tokens: 27954,
          toolUses: 1,
        },
      ],
    },
    subagents: [
      {
        action: "Report: report",
        agents: {
          done: 3,
          started: 3,
        },
        elapsedMs: 10761,
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "running",
        tokens: 84080,
        toolUses: 5,
        workflowAgents: [
          {
            action: "find . -maxdepth 1 -type f | wc -l",
            elapsedMs: 4195,
            index: 3,
            lastProgressAt: 10774,
            result: "The recount found 2 regular files, which matches the counts from agent A (2) and agent B (2).",
            state: "completed",
            tokens: 27954,
            toolUses: 1,
          },
        ],
      },
    ],
  },
  {
    at: 10780,
    update: {
      agents: {
        done: 3,
        started: 3,
      },
      elapsedMs: 10753,
      phases: [
        {
          index: 1,
          title: "Count",
        },
        {
          index: 2,
          title: "Report",
        },
      ],
      runId: "workflow-run-1",
      scriptPath: "/workspace/workflows/scripts/count-files-fixture-workflow-run-1.js",
      sessionUpdate: "subagent_progress",
      subagentSessionId: "workflow-session/tool-workflow",
      tokens: 84080,
      toolUses: 5,
      workflowAgents: [
        {
          action: "StructuredOutput",
          agentId: "workflow-agent-1",
          attempt: 1,
          elapsedMs: 5054,
          index: 1,
          label: "count-a",
          lastProgressAt: 5119,
          model: "claude-opus-5-5",
          phase: "Count",
          phaseIndex: 1,
          prompt:
            "Count the regular files (not directories) directly in the current working directory, non-recursive, including hidden files. Use one shell command such as `find . -maxdepth 1 -type f | wc -l`. Return the count.",
          queuedAt: 48,
          result: '{"count":2}',
          startedAt: 64,
          state: "completed",
          tokens: 28053,
          toolUses: 2,
        },
        {
          action: "StructuredOutput",
          agentId: "workflow-agent-2",
          attempt: 1,
          elapsedMs: 4640,
          index: 2,
          label: "count-b",
          lastProgressAt: 6577,
          model: "claude-opus-5-5",
          phase: "Count",
          phaseIndex: 1,
          prompt:
            "Count the files directly in the current working directory (non-recursive, regular files only, hidden included) using `ls -A` and filtering out directories. Return the count.",
          queuedAt: 48,
          result: '{"count":2}',
          startedAt: 64,
          state: "completed",
          tokens: 28073,
          toolUses: 2,
        },
        {
          action: "find . -maxdepth 1 -type f | wc -l",
          agentId: "workflow-agent-3",
          attempt: 1,
          elapsedMs: 4195,
          index: 3,
          label: "report",
          lastProgressAt: 10774,
          model: "claude-opus-5-5",
          phase: "Report",
          phaseIndex: 2,
          prompt:
            "Two agents counted the regular files in the current folder: agent A got 2, agent B got 2. Recount once with `find . -maxdepth 1 -type f | wc -l` and report the final count in one short sentence, noting whether the counts agreed.",
          queuedAt: 6578,
          result: "The recount found 2 regular files, which matches the counts from agent A (2) and agent B (2).",
          startedAt: 6579,
          state: "completed",
          tokens: 27954,
          toolUses: 1,
        },
      ],
      workflowAgentsFull: true,
    },
    subagents: [
      {
        agents: {
          done: 3,
          started: 3,
        },
        elapsedMs: 10753,
        id: "workflow-session/tool-workflow",
        parent: null,
        phases: [
          {
            index: 1,
            title: "Count",
          },
          {
            index: 2,
            title: "Report",
          },
        ],
        runId: "workflow-run-1",
        scriptPath: "/workspace/workflows/scripts/count-files-fixture-workflow-run-1.js",
        state: "running",
        tokens: 84080,
        toolUses: 5,
        workflowAgents: [
          {
            action: "StructuredOutput",
            agentId: "workflow-agent-1",
            attempt: 1,
            elapsedMs: 5054,
            index: 1,
            label: "count-a",
            lastProgressAt: 5119,
            model: "claude-opus-5-5",
            phase: "Count",
            phaseIndex: 1,
            prompt:
              "Count the regular files (not directories) directly in the current working directory, non-recursive, including hidden files. Use one shell command such as `find . -maxdepth 1 -type f | wc -l`. Return the count.",
            queuedAt: 48,
            result: '{"count":2}',
            startedAt: 64,
            state: "completed",
            tokens: 28053,
            toolUses: 2,
          },
          {
            action: "StructuredOutput",
            agentId: "workflow-agent-2",
            attempt: 1,
            elapsedMs: 4640,
            index: 2,
            label: "count-b",
            lastProgressAt: 6577,
            model: "claude-opus-5-5",
            phase: "Count",
            phaseIndex: 1,
            prompt:
              "Count the files directly in the current working directory (non-recursive, regular files only, hidden included) using `ls -A` and filtering out directories. Return the count.",
            queuedAt: 48,
            result: '{"count":2}',
            startedAt: 64,
            state: "completed",
            tokens: 28073,
            toolUses: 2,
          },
          {
            action: "find . -maxdepth 1 -type f | wc -l",
            agentId: "workflow-agent-3",
            attempt: 1,
            elapsedMs: 4195,
            index: 3,
            label: "report",
            lastProgressAt: 10774,
            model: "claude-opus-5-5",
            phase: "Report",
            phaseIndex: 2,
            prompt:
              "Two agents counted the regular files in the current folder: agent A got 2, agent B got 2. Recount once with `find . -maxdepth 1 -type f | wc -l` and report the final count in one short sentence, noting whether the counts agreed.",
            queuedAt: 6578,
            result: "The recount found 2 regular files, which matches the counts from agent A (2) and agent B (2).",
            startedAt: 6579,
            state: "completed",
            tokens: 27954,
            toolUses: 1,
          },
        ],
        workflowAgentsFull: true,
      },
    ],
  },
  {
    at: 10780,
    update: {
      sessionUpdate: "subagent_state_update",
      state: "completed",
      subagentSessionId: "workflow-session/tool-workflow",
    },
    subagents: [
      {
        id: "workflow-session/tool-workflow",
        parent: null,
        state: "completed",
      },
    ],
  },
];

/// Anchors a recorded workflow agent's relative times to the replay's clock.
const anchorAgents = (fields: Record<string, unknown>, start: number): Record<string, unknown> => {
  if (!Array.isArray(fields.workflowAgents)) return fields;
  const workflowAgents = fields.workflowAgents.map((entry) =>
    Object.fromEntries(
      Object.entries(entry as Record<string, unknown>).map(([key, value]) => [
        key,
        AGENT_TIMES.has(key) && typeof value === "number" ? start + value : value,
      ]),
    ),
  );
  return { ...fields, workflowAgents };
};

/// Feed the captured records through the production SubagentFold, preserving event order and timing.
export function realWorkflowFixture(now = Date.now(), throughAt = REAL_WORKFLOW_RECORDING.at(-1)!.at): Subagent[] {
  const fold = new SubagentFold();
  const records = REAL_WORKFLOW_RECORDING.filter((record) => record.at <= throughAt);
  const start = now - throughAt;
  records.forEach((record, index) => {
    const update = anchorAgents(record.update, start);
    const subagents = record.subagents.map((change) => anchorAgents(change, start));
    const msg = { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } };
    fold.reduce({ seq: index + 1, at: start + record.at, msg }, update);
  });
  return fold.all();
}
