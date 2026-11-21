import { describe, expect, test } from "bun:test";
import type { Translate } from "../../i18n";
import { RESUME_CAPABILITY, SUBSESSION_RESUME_CAPABILITY, type ResumeRun } from "../../subagents/resumeState";
import type { StartedSession } from "../../started/startedSessions";
import type { Subagent } from "../../subagents/subagentFold";
import { NativeInfoActions } from "./model";
import { subagentsSection, type SubagentsSectionInput } from "./subagents";

const t = ((key: string) => key) as Translate;
const agent = (over: Partial<Subagent>): Subagent =>
  ({ id: "s/t1", name: "Reviewer", parent: null, state: "cancelled", startedAt: 1, endedAt: 2, ...over }) as Subagent;

function rows(agents: Subagent[], resume: SubagentsSectionInput["resume"], sessions: StartedSession[] = []) {
  const actions = new NativeInfoActions();
  const section = subagentsSection(
    { open: true, agents, waiting: new Set(), sessions, now: 3, endedOpen: true, ...(resume && { resume }) },
    actions,
    t,
  );
  return { rows: section?.rows ?? [], actions };
}

describe("Session Info's native Subagents: Resume on a stopped one", () => {
  const capabilities = new Set([RESUME_CAPABILITY]);

  test("a stopped subagent acpmux can resume has Resume, and its click resumes it", async () => {
    const ran: string[] = [];
    const { rows: drawn, actions } = rows(
      [agent({ resumable: true }), agent({ id: "s/t2", state: "completed", resumable: true })],
      { capabilities, run: (a) => ran.push(a.id), shown: () => undefined },
    );
    const stopped = drawn.find((row) => row.id === "agent:s/t1");
    expect(stopped?.buttons).toEqual([
      { label: "subagents.resume", symbol: "arrow.clockwise", action: expect.any(String) },
    ]);
    expect(drawn.find((row) => row.id === "agent:s/t2")?.buttons).toBeUndefined();
    expect(actions.run(stopped!.buttons![0]!.action)).toBe(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(ran).toEqual(["s/t1"]);
  });

  test("busy disables it, a refusal says why on the row, and no Resume without the chat's action", () => {
    const busy: ResumeRun = { version: "v", busy: true };
    const refused: ResumeRun = { version: "v", key: "retry.busy" };
    const busyRow = rows([agent({ resumable: true })], { capabilities, run: () => {}, shown: () => busy }).rows[1];
    expect(busyRow?.buttons?.[0]?.disabled).toBe(true);
    const refusedRow = rows([agent({ resumable: true })], { capabilities, run: () => {}, shown: () => refused })
      .rows[1];
    expect(refusedRow?.detail).toBe("retry.busy");
    expect(rows([agent({ resumable: true })], undefined).rows[1]?.buttons).toBeUndefined();
    expect(
      rows([agent({ resumable: true, harness: "codex" })], { capabilities, run: () => {}, shown: () => undefined })
        .rows[1]?.buttons,
    ).toBeUndefined();
  });
});

describe("Session Info's native Subagents: Resume on a stopped sub-session", () => {
  const capabilities = new Set([SUBSESSION_RESUME_CAPABILITY]);
  const session = (over: Partial<StartedSession> = {}): StartedSession => ({
    sessionId: "child-1",
    title: "Run the tests",
    state: "idle",
    subsession: true,
    ...over,
  });

  test("a stopped one reads stopped and has Resume, which resumes its own session", async () => {
    const ran: Subagent[] = [];
    const { rows: drawn, actions } = rows([], { capabilities, run: (a) => ran.push(a), shown: () => undefined }, [
      session({ stoppedAt: 5 }),
      session({ sessionId: "child-2" }),
    ]);
    const stopped = drawn.find((row) => row.id === "session:child-1");
    expect(stopped?.trailing).toBe("subagents.state.cancelled");
    expect(stopped?.buttons?.[0]?.label).toBe("subagents.resume");
    // One whose last turn completed is done, with no Resume.
    const done = drawn.find((row) => row.id === "session:child-2");
    expect([done?.trailing, done?.buttons]).toEqual(["subagents.state.completed", undefined]);
    expect(actions.run(stopped!.buttons![0]!.action)).toBe(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(ran.map((a) => a.child)).toEqual(["child-1"]);
  });

  test("no Resume where acpmux does not serve it", () => {
    const { rows: drawn } = rows(
      [],
      { capabilities: new Set([RESUME_CAPABILITY]), run: () => {}, shown: () => undefined },
      [session({ stoppedAt: 5 })],
    );
    expect(drawn.find((row) => row.id === "session:child-1")?.buttons).toBeUndefined();
  });
});
