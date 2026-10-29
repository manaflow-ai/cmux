// l10n-allow-file: test fixture names, prompts and commands, not shipped UI.
// Session Info drawn natively (inspector/native/model.ts): the page maps Subagents and Background
// tasks to plain rows the App draws, and a click comes back by action id. These check the mappers
// keep what the web sections do: the head's counts, the running limit's − and + (the values the
// stepper sends, off at the bounds), a subagent opening, nesting, Stop on running commands only and a
// server opening its address.
import { expect, test } from "bun:test";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { SubsessionLimits } from "../src/agent-session/acpmux/model";
import { NativeInfoActions, type NativeInfoRow } from "../src/agent-session/acpmux/inspector/native/model";
import { subagentsSection, type SubagentsSectionInput } from "../src/agent-session/acpmux/inspector/native/subagents";
import { tasksSection, type TasksSectionInput } from "../src/agent-session/acpmux/inspector/native/tasks";
import { subagentCounts } from "../src/agent-session/acpmux/inspector/SubagentsSection";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { WorkflowSummary } from "../src/agent-session/acpmux/summary/workflow";

const t = translatorFor("en");
const NOW = 1_000_000;

const agent = (id: string, extra: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: `agent ${id}`,
  state: "running",
  startedAt: NOW - 30_000,
  ...extra,
});

const subagents = (extra: Partial<SubagentsSectionInput> = {}): SubagentsSectionInput => ({
  open: true,
  agents: [],
  waiting: new Set(),
  sessions: [],
  now: NOW,
  ...extra,
});

const tasks = (extra: Partial<TasksSectionInput> = {}): TasksSectionInput => ({
  open: true,
  processes: [],
  transcriptTasks: [],
  listed: true,
  scheduled: [],
  workflows: [],
  local: true,
  now: NOW,
  ...extra,
});

/// Runs an action and lets its microtask settle.
async function click(actions: NativeInfoActions, id: string | undefined) {
  expect(id).toBeDefined();
  expect(actions.run(id!)).toBe(true);
  await Promise.resolve();
  await Promise.resolve();
}

const row = (rows: readonly NativeInfoRow[], id: string) => {
  const found = rows.find((each) => each.id === id);
  expect(found).toBeDefined();
  return found!;
};

test("Subagents shows only with subagents, started chats or a set limit", () => {
  const actions = new NativeInfoActions();
  expect(subagentsSection(subagents(), actions, t)).toBeUndefined();
  const limits: SubsessionLimits = { maxRunning: 8, maxRunningSource: "default" };
  expect(subagentsSection(subagents({ limits }), actions, t)).toBeUndefined();
  const set = subagentsSection(subagents({ limits: { maxRunning: 8, maxRunningSource: "settings" } }), actions, t);
  expect(set?.id).toBe("subagents");
  expect(set?.group).toBe("running");
  expect(set?.rows.map((each) => each.id)).toEqual(["limit"]);
  // A workflow Background tasks lists is not a Subagents row too.
  expect(subagentsSection(subagents({ agents: [agent("w")], workflows: [{ id: "w" }] }), actions, t)).toBeUndefined();
});

test("Subagents' meta counts as the web head does", () => {
  const agents = [agent("a"), agent("b"), agent("c", { state: "completed", endedAt: NOW }), agent("d")];
  const waiting = new Set(["d"]);
  const section = subagentsSection(subagents({ agents, waiting }), new NativeInfoActions(), t)!;
  expect(section.meta).toBe(subagentCounts(t, agents, waiting, []));
  expect(section.meta).toBe(
    [
      t("summary.subagents.waiting", { n: 1 }),
      t("summary.subagents.running", { n: 2 }),
      t("summary.subagents.done", { n: 1 }),
    ].join(" · "),
  );
});

test("the limit's − and + send the stepper's values and are off at the bounds", async () => {
  const sent: [number | null, number | undefined][] = [];
  const onSet = async (maxRunning: number | null, from?: number) => {
    sent.push([maxRunning, from]);
  };
  const actions = new NativeInfoActions();
  const section = subagentsSection(
    subagents({ agents: [agent("a")], limits: { maxRunning: 8, maxRunningSource: "session" }, onSet }),
    actions,
    t,
  )!;
  const limit = row(section.rows, "limit");
  expect(limit.title).toBe(t("chatInspector.subagents.limit.running", { running: 0, max: 8 }));
  expect(limit.trailing).toBe("8");
  const [reset, lower, raise] = limit.buttons!;
  expect(lower!.disabled).toBeUndefined();
  expect(raise!.disabled).toBeUndefined();
  await click(actions, lower!.action);
  await click(actions, raise!.action);
  await click(actions, reset!.action);
  expect(sent).toEqual([
    [7, 8],
    [9, 8],
    [null, undefined],
  ]);

  const atMin = subagentsSection(
    subagents({ limits: { maxRunning: 1, maxRunningSource: "settings" }, onSet }),
    actions,
    t,
  )!;
  const [minLower, minRaise] = row(atMin.rows, "limit").buttons!;
  expect(minLower!.disabled).toBe(true);
  expect(minRaise!.disabled).toBeUndefined();
  const atMax = subagentsSection(
    subagents({ limits: { maxRunning: 1000, maxRunningSource: "settings" }, onSet }),
    actions,
    t,
  )!;
  const [maxLower, maxRaise] = row(atMax.rows, "limit").buttons!;
  expect(maxLower!.disabled).toBeUndefined();
  expect(maxRaise!.disabled).toBe(true);

  // Without onSet the limit only reads.
  const readOnly = subagentsSection(
    subagents({ limits: { maxRunning: 8, maxRunningSource: "settings" } }),
    actions,
    t,
  )!;
  expect(row(readOnly.rows, "limit").buttons).toBeUndefined();
});

test("a subagent's row opens it, a nested one sits under its parent", async () => {
  const opened: string[] = [];
  const actions = new NativeInfoActions();
  const section = subagentsSection(
    subagents({
      agents: [
        agent("parent", { action: "Reading files" }),
        agent("child", { parent: "parent", startedAt: NOW - 10_000 }),
      ],
      onOpen: (id) => opened.push(id),
    }),
    actions,
    t,
  )!;
  expect(section.rows.map((each) => each.id)).toEqual(["agent:parent", "agent:child"]);
  const parent = row(section.rows, "agent:parent");
  expect(parent.title).toBe("agent parent");
  expect(parent.detail).toBe("Reading files");
  expect(parent.tone).toBe("running");
  expect(parent.trailing).toBe(`30s · ${t("subagents.state.running")}`);
  expect(parent.indent).toBeUndefined();
  expect(row(section.rows, "agent:child").indent).toBe(1);
  await click(actions, row(section.rows, "agent:child").action);
  expect(opened).toEqual(["child"]);
});

test("started chats open by session, ended lines fold under their row", async () => {
  const opened: string[] = [];
  let endedOpen: boolean | undefined;
  const actions = new NativeInfoActions();
  const input = subagents({
    agents: [agent("done", { state: "completed", endedAt: NOW })],
    sessions: [{ sessionId: "s1", title: "Child chat", state: "running" }],
    onOpenSession: (id) => opened.push(id),
    onEndedOpen: (open) => (endedOpen = open),
  });
  const closed = subagentsSection(input, actions, t)!;
  expect(closed.rows.map((each) => each.id)).toEqual(["session:s1", "ended"]);
  await click(actions, row(closed.rows, "session:s1").action);
  expect(opened).toEqual(["s1"]);
  await click(actions, row(closed.rows, "ended").action);
  expect(endedOpen).toBe(true);
  const open = subagentsSection({ ...input, endedOpen: true }, new NativeInfoActions(), t)!;
  expect(open.rows.map((each) => each.id)).toEqual(["session:s1", "ended", "agent:done"]);
  expect(row(open.rows, "agent:done").tone).toBe("done");
});

test("Background tasks' meta counts running commands, servers and workflows", () => {
  const section = tasksSection(
    tasks({
      processes: [
        { id: "p/1", command: "pytest -x", startedAt: NOW - 5_000, state: "running", toolCallId: "c1" },
        { id: "p/2", command: "bun run dev --port 5173", startedAt: NOW - 5_000, state: "running" },
        { id: "p/3", command: "make", startedAt: NOW - 9_000, endedAt: NOW - 1_000, state: "exited" },
      ],
    }),
    new NativeInfoActions(),
    t,
  )!;
  expect(section.meta).toBe(t("rail.running", { count: 2 }));
  expect(section.metaTone).toBe("running");
  expect(tasksSection(tasks(), new NativeInfoActions(), t)).toBeUndefined();
  const idle = tasksSection(
    tasks({ scheduled: [{ id: "w1", text: "check CI", cron: "*/5 * * * *" }] }),
    new NativeInfoActions(),
    t,
  )!;
  expect(idle.meta).toBeUndefined();
  expect(row(idle.rows, "scheduled:w1")).toMatchObject({ symbol: "clock", trailing: "*/5 * * * *" });
});

test("Stop shows on running commands only and stops by process id", async () => {
  const stopped: string[] = [];
  let finishedOpen = false;
  const actions = new NativeInfoActions();
  const input = tasks({
    processes: [
      { id: "p/1", command: "pytest -x", startedAt: NOW - 5_000, state: "running", toolCallId: "c1" },
      { id: "p/3", command: "make", startedAt: NOW - 9_000, endedAt: NOW - 1_000, state: "exited", toolCallId: "c3" },
    ],
    transcriptTasks: [{ id: "c4", command: "sleep 100", state: "running", startedAt: NOW - 1_000 }],
    listed: false,
    onStopProcess: async (id) => {
      stopped.push(id);
    },
    finishedOpen: true,
    onFinishedOpen: (open) => (finishedOpen = open),
  });
  const section = tasksSection(input, actions, t)!;
  expect(section.rows.map((each) => each.id)).toEqual(["command:c4", "command:c1", "finished", "command:c3"]);
  const running = row(section.rows, "command:c1");
  expect(running.tone).toBe("running");
  expect(running.trailing).toBe("5s");
  expect(running.buttons?.length).toBe(1);
  // A transcript-only command has no registry id to stop.
  expect(row(section.rows, "command:c4").buttons).toBeUndefined();
  const ended = row(section.rows, "command:c3");
  expect(ended.buttons).toBeUndefined();
  expect(ended.trailing).toBe(`8s · ${t("bgTask.state.completed")}`);
  expect(ended.tone).toBe("done");
  await click(actions, running.buttons![0]!.action);
  expect(stopped).toEqual(["p/1"]);
  await click(actions, row(section.rows, "finished").action);
  expect(finishedOpen).toBe(false);
  const folded = tasksSection({ ...input, finishedOpen: false }, new NativeInfoActions(), t)!;
  expect(folded.rows.map((each) => each.id)).toEqual(["command:c4", "command:c1", "finished"]);
});

test("a remote command without its call in the transcript opens nothing and says why", () => {
  const section = tasksSection(
    tasks({
      local: false,
      calls: new Set(["c2"]),
      onShowCall: () => true,
      processes: [
        { id: "p/1", command: "pytest", startedAt: NOW, state: "running", toolCallId: "c1" },
        { id: "p/2", command: "ruff", startedAt: NOW - 1, state: "running", toolCallId: "c2" },
      ],
    }),
    new NativeInfoActions(),
    t,
  )!;
  const closed = row(section.rows, "command:c1");
  expect(closed.action).toBeUndefined();
  expect(closed.help).toBe(t("chatInspector.tasks.noTerminal.remote"));
  expect(row(section.rows, "command:c2").action).toBe("tasks.open:c2");
});

test("a server's row opens its address beside the chat, and Stop stops it", async () => {
  const urls: string[] = [];
  const stopped: string[] = [];
  const actions = new NativeInfoActions();
  const section = tasksSection(
    tasks({
      processes: [{ id: "p/2", command: "bun run dev --port 5173", startedAt: NOW - 61_000, state: "running" }],
      onOpenUrl: (url) => urls.push(url),
      onStopProcess: async (id) => {
        stopped.push(id);
      },
    }),
    actions,
    t,
  )!;
  const server = row(section.rows, "server:p/2");
  expect(server).toMatchObject({
    symbol: "server.rack",
    title: "bun run dev --port 5173",
    trailing: ":5173",
    detail: "1m 1s",
  });
  await click(actions, server.action);
  expect(urls).toEqual(["http://localhost:5173"]);
  await click(actions, server.buttons![0]!.action);
  expect(stopped).toEqual(["p/2"]);
});

test("a workflow nests its phases and their agents, and stops while it runs", async () => {
  const stopped: string[] = [];
  const opened: string[] = [];
  const workflow: WorkflowSummary = {
    id: "wf1",
    title: "Review",
    state: "running",
    startedAt: NOW - 2_000,
    phases: [
      { id: "ph1", name: "Find", state: "running", agentIds: ["a1"] },
      { id: "ph2", name: "Fix", state: "pending", agentIds: ["a2"] },
    ],
    agents: [
      { id: "a1", name: "finder", state: "running", startedAt: NOW - 1_000 },
      { id: "a2", name: "fixer", state: "pending" },
    ],
  };
  const actions = new NativeInfoActions();
  const section = tasksSection(
    tasks({
      workflows: [workflow],
      onStopWorkflow: async (id) => {
        stopped.push(id);
      },
      onOpenWorkflowAgent: (each) => opened.push(each.id),
    }),
    actions,
    t,
  )!;
  expect(section.meta).toBe(t("rail.running", { count: 1 }));
  expect(section.rows.map((each) => [each.id, each.indent ?? 0])).toEqual([
    ["workflow:wf1", 0],
    ["phase:wf1/ph1", 1],
    ["workflowAgent:wf1/a1", 2],
    ["upNext:wf1", 1],
  ]);
  await click(actions, row(section.rows, "workflow:wf1").buttons![0]!.action);
  expect(stopped).toEqual(["wf1"]);
  await click(actions, row(section.rows, "workflowAgent:wf1/a1").action);
  expect(opened).toEqual(["a1"]);
  // A finished workflow has no Stop.
  const done = tasksSection(
    tasks({ workflows: [{ ...workflow, state: "completed" }], onStopWorkflow: async () => {} }),
    new NativeInfoActions(),
    t,
  )!;
  expect(row(done.rows, "workflow:wf1").buttons).toBeUndefined();
});
