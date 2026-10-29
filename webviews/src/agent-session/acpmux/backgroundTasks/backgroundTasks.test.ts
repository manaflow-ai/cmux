import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import type { BackgroundCommand } from "../inspector/processes";
import type { StartedSession } from "../started/startedSessions";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { anyRunning, backgroundGroups, finishedGroupIds, type TaskCache } from "./backgroundTasks";

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
