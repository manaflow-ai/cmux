import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import type { BackgroundCommand } from "../session-info/processes";
import type { StartedSession } from "../started/startedSessions";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { workflowPaneId } from "../summary/workflowTranscript";
import { anyRunning, backgroundGroups, clearKey, finishedGroupIds, type TaskCache } from "./backgroundTasks";

const agent = (id: string, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  task: `Task ${id}`,
  state: "running",
  startedAt: 1_000,
  ...fields,
});
const group = (agents: Subagent[]): AcpmuxRow => ({
  id: `g-${agents[0]!.id}`,
  version: 1,
  at: 1_000,
  kind: SUBAGENTS,
  subagents: agents,
});
const call = (id: string, status: string, startedAt: number, endedAt?: number, description?: string) => ({
  kind: "tool",
  text: id,
  tool: { id, title: `title ${id}`, status, startedAt, endedAt, description },
});
const activity = (id: string, items: ReturnType<typeof call>[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 2_000,
  kind: "activity",
  items,
});

const input = (
  rows: AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> = {},
  extra: Partial<Parameters<typeof backgroundGroups>[0]> = {},
) => ({
  rows,
  views,
  commands: [] as BackgroundCommand[],
  sessions: [] as StartedSession[],
  chatName: "The chat",
  ...extra,
});

describe("backgroundGroups", () => {
  test("a subagent's tool calls are its tasks: running first oldest first, then finished latest first, with failures counted", () => {
    const rows = [group([agent("a")])];
    const views = {
      a: [
        activity("r1", [call("t1", "completed", 1_000, 1_500), call("t2", "failed", 1_600, 1_700, "Run the tests")]),
        activity("r2", [
          call("t3", "in_progress", 3_000),
          call("t4", "in_progress", 2_500),
          call("t5", "completed", 1_800, 4_000),
        ]),
      ],
    };
    const [only] = backgroundGroups(input(rows, views));
    expect(only!.id).toBe("agent:a");
    expect(only!.name).toBe("Task a");
    expect(only!.running.map((task) => task.id)).toEqual(["t4", "t3"]);
    expect(only!.finished.map((task) => task.id)).toEqual(["t5", "t2", "t1"]);
    expect(only!.finished[1]!.title).toBe("Run the tests");
    expect(only!.finished[1]!.rowId).toBe("r1");
    expect(only!.total).toBe(5);
    expect(only!.failed).toBe(1);
    expect(only!.stop).toEqual({ kind: "agent", id: "a" });
  });

  test("a call left in flight by an agent that ended reads stopped, not running", () => {
    const rows = [group([agent("a", { state: "completed", endedAt: 9_000 })])];
    const views = { a: [activity("r1", [call("t1", "in_progress", 1_000)])] };
    const [only] = backgroundGroups(input(rows, views));
    expect(only!.running).toEqual([]);
    expect(only!.finished[0]!.state).toBe("stopped");
    expect(only!.stop).toBeUndefined();
  });

  test("a nested subagent is a task of its parent that opens its own transcript", () => {
    const rows = [group([agent("a")])];
    const views = { a: [group([agent("b", { parent: "a", task: "Explore", startedAt: 1_200 })])] };
    const groups = backgroundGroups(input(rows, views));
    expect(groups.map((g) => g.id)).toEqual(["agent:a"]);
    expect(groups[0]!.running).toHaveLength(1);
    expect(groups[0]!.running[0]).toMatchObject({
      id: "b",
      kind: "agent",
      title: "Explore",
      agentId: "b",
      stop: { kind: "agent", id: "b" },
    });
  });

  test("an agent nested two deep is a task of the top agent that opens and stops on its own", () => {
    const rows = [group([agent("a")])];
    const views = {
      a: [group([agent("b", { parent: "a", startedAt: 1_200 })])],
      b: [group([agent("c", { parent: "b", task: "Grep", startedAt: 1_400 })])],
    };
    const groups = backgroundGroups(input(rows, views));
    expect(groups.map((g) => g.id)).toEqual(["agent:a"]);
    expect(groups[0]!.running.map((task) => task.id)).toEqual(["b", "c"]);
    expect(groups[0]!.running[1]).toMatchObject({ agentId: "c", title: "Grep", stop: { kind: "agent", id: "c" } });
  });

  test("a workflow nested under an agent lists its started agents, each opening its transcript", () => {
    const workflow = agent("wf", {
      parent: "a",
      kind: "workflow",
      runId: "wf_run",
      startedAt: 1_300,
      workflowAgents: new Map([
        [1, { index: 1, label: "critic", agentId: "crit", state: "running", startedAt: 1_400 }],
        [2, { index: 2, label: "later", state: "queued" }],
      ]),
    });
    const groups = backgroundGroups(input([group([agent("a")])], { a: [group([workflow])] }, { sessionId: "chat" }));
    expect(groups.map((g) => g.id)).toEqual(["agent:a"]);
    const critic = groups[0]!.running.find((task) => task.title === "critic");
    expect(critic?.workflow?.pane).toBe(workflowPaneId({ sessionId: "chat", runId: "wf_run", agentId: "crit" }));
    // The nested workflow's own line stops the whole run, as the workflow pane's Stop does.
    expect(groups[0]!.running.find((task) => task.id === "wf")).toMatchObject({ stop: { kind: "agent", id: "wf" } });
  });

  test("a workflow's agents carry no stop of their own; the workflow's line stops the run", () => {
    const workflow = agent("wf", {
      kind: "workflow",
      runId: "wf_run",
      workflowAgents: new Map([
        [1, { index: 1, label: "critic", agentId: "crit", state: "running", startedAt: 1_400 }],
      ]),
    });
    const [only] = backgroundGroups(input([group([workflow])], {}, { sessionId: "chat" }));
    expect(only).toMatchObject({ stop: { kind: "agent", id: "wf" } });
    expect(only!.agentId).toBeUndefined();
    expect(only!.running.map((task) => task.stop)).toEqual([undefined]);
  });

  test("a paused workflow reads stopped: no spinner, no clock, no stop, and Clear finished clears it", () => {
    const workflow = agent("wf", {
      kind: "workflow",
      runId: "wf_run",
      paused: true,
      workflowAgents: new Map([
        [1, { index: 1, label: "critic", agentId: "crit", state: "running", startedAt: 1_400 }],
      ]),
    });
    const groups = backgroundGroups(input([group([workflow])], {}, { sessionId: "chat" }));
    expect(groups[0]).toMatchObject({ state: "stopped", running: [] });
    expect(groups[0]!.stop).toBeUndefined();
    expect(groups[0]!.finished.map((task) => task.state)).toEqual(["stopped"]);
    expect(anyRunning(groups)).toBe(false);
    expect(finishedGroupIds(groups)).toEqual([clearKey(groups[0]!)]);
  });

  test("a workflow that ended (a cancel, the harness exiting) leaves none of its agents running", () => {
    const workflow = agent("wf", {
      kind: "workflow",
      runId: "wf_run",
      state: "cancelled",
      endedAt: 5_000,
      workflowAgents: new Map([
        [1, { index: 1, label: "critic", agentId: "crit", state: "running", startedAt: 1_400 }],
        [2, { index: 2, label: "judge", agentId: "judge", state: "completed", startedAt: 1_500, elapsedMs: 100 }],
      ]),
    });
    const groups = backgroundGroups(input([group([workflow])], {}, { sessionId: "chat" }));
    expect(groups[0]!.running).toEqual([]);
    expect(groups[0]!.finished.map((task) => [task.title, task.state])).toEqual(
      expect.arrayContaining([
        ["critic", "stopped"],
        ["judge", "done"],
      ]),
    );
    expect(anyRunning(groups)).toBe(false);
    expect(finishedGroupIds(groups)).toEqual([clearKey(groups[0]!)]);
  });

  test("an agent that ended while a nested agent still runs stays live: ordered with the running, never cleared", () => {
    const rows = [
      group([
        agent("parent", { state: "completed", startedAt: 500, endedAt: 9_000 }),
        agent("done", { state: "completed", endedAt: 10_000 }),
        agent("busy", { startedAt: 2_000 }),
      ]),
    ];
    const views = { parent: [group([agent("child", { parent: "parent", startedAt: 600 })])] };
    const groups = backgroundGroups(input(rows, views));
    expect(groups.map((g) => g.id)).toEqual(["agent:parent", "agent:busy", "agent:done"]);
    expect(finishedGroupIds(groups)).toEqual([clearKey(groups.find((g) => g.id === "agent:done")!)]);
    expect(anyRunning(groups)).toBe(true);
    const dismissed = new Set(groups.filter((g) => g.id !== "agent:busy").map(clearKey));
    const cleared = backgroundGroups(input(rows, views, { dismissed }));
    expect(cleared.map((g) => g.id)).toEqual(["agent:parent", "agent:busy"]);
  });

  test("commands that ended with one stopped or lost and none failed read stopped, as each stopped one does", () => {
    const commands: BackgroundCommand[] = [
      { id: "c1", command: "make", state: "completed", startedAt: 500, endedAt: 900 },
      { id: "c2", command: "tail -f log", state: "lost", startedAt: 600, endedAt: 950 },
      { id: "c3", command: "watch", state: "stopped", startedAt: 700, endedAt: 800 },
    ];
    const [commandsGroup] = backgroundGroups(input([], {}, { commands }));
    expect(commandsGroup!.state).toBe("stopped");
    expect(commandsGroup!.finished.map((task) => [task.id, task.state])).toEqual([
      ["c2", "stopped"],
      ["c1", "done"],
      ["c3", "stopped"],
    ]);
    expect(commandsGroup!.endedAt).toBe(950);
  });

  test("running groups first oldest first, then ended groups latest first; cleared ended groups leave", () => {
    const rows = [
      group([
        agent("late", { startedAt: 5_000 }),
        agent("early", { startedAt: 1_000 }),
        agent("done1", { state: "completed", endedAt: 3_000 }),
        agent("done2", { state: "failed", endedAt: 4_000 }),
      ]),
    ];
    const ids = backgroundGroups(input(rows)).map((g) => g.id);
    expect(ids).toEqual(["agent:early", "agent:late", "agent:done2", "agent:done1"]);
    const cleared = backgroundGroups(
      input(rows, {}, { dismissed: new Set(finishedGroupIds(backgroundGroups(input(rows)))) }),
    );
    expect(cleared.map((g) => g.id)).toEqual(["agent:early", "agent:late"]);
  });

  test("a cleared group that runs again and ends again shows again", () => {
    const first = [group([agent("a", { state: "completed", startedAt: 1_000, endedAt: 2_000 })])];
    const dismissed = new Set(finishedGroupIds(backgroundGroups(input(first))));
    expect(backgroundGroups(input(first, {}, { dismissed }))).toEqual([]);
    const again = [group([agent("a", { state: "completed", startedAt: 5_000, endedAt: 6_000 })])];
    expect(backgroundGroups(input(again, {}, { dismissed })).map((g) => g.id)).toEqual(["agent:a"]);
  });

  test("the chat's background commands are one group under the chat's name, a registry command stoppable", () => {
    const commands: BackgroundCommand[] = [
      {
        id: "p1",
        command: "bun run dev",
        description: "Dev server",
        state: "running",
        processId: "p1",
        startedAt: 1_000,
      },
      { id: "c2", command: "make", state: "failed", startedAt: 500, endedAt: 900 },
    ];
    const [commandsGroup] = backgroundGroups(input([], {}, { commands }));
    expect(commandsGroup!.name).toBe("The chat");
    expect(commandsGroup!.state).toBe("running");
    expect(commandsGroup!.running[0]).toMatchObject({ title: "Dev server", stop: { kind: "process", id: "p1" } });
    expect(commandsGroup!.failed).toBe(1);
  });

  test("a started chat is a group of its own that opens the chat", () => {
    const sessions = [{ sessionId: "s1", title: "Side quest", state: "running", createdAt: 2_000 } as StartedSession];
    const [chat] = backgroundGroups(input([], {}, { sessions }));
    expect(chat).toMatchObject({ id: "chat:s1", kind: "chat", sessionId: "s1", state: "running", total: 0 });
  });

  test("a view is read once while it is the same array: a snapshot that streams elsewhere re-reads nothing", () => {
    const rows = [group([agent("a")])];
    const view = [activity("r1", [call("t1", "in_progress", 1_000)])];
    const cache: TaskCache = new WeakMap();
    const first = backgroundGroups(input(rows, { a: view }), cache);
    const second = backgroundGroups(input(rows, { a: view }), cache);
    expect(second[0]!.running[0]).toBe(first[0]!.running[0]!);
    expect(cache.get(view)?.tasks.length).toBe(1);
  });

  test("anyRunning stops the clock once nothing runs", () => {
    const ended = [group([agent("a", { state: "completed", endedAt: 2_000 })])];
    expect(anyRunning(backgroundGroups(input(ended)))).toBe(false);
    expect(anyRunning(backgroundGroups(input([group([agent("a")])])))).toBe(true);
  });
});
