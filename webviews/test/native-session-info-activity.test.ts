// l10n-allow-file: deterministic Session Info activity fixtures.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { subagentsSection } from "../src/agent-session/acpmux/session-info/native/subagents";
import { tasksSection } from "../src/agent-session/acpmux/session-info/native/tasks";
import {
  nativeInfoWave,
  SESSION_INFO_WAVE_PERIOD_MS,
  SESSION_INFO_WAVE_STEP_MS,
} from "../src/agent-session/acpmux/session-info/native/wave";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { IDLE_AFTER_MS } from "../src/agent-session/acpmux/subagents/idle";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";

const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

test("native subagent rows retain progress, kind/task help, retry spinner and the shared wave", () => {
  const agents: Subagent[] = [
    {
      id: "retry",
      parent: null,
      name: "Retry",
      kind: "Explore",
      task: "Retry the request",
      state: "failed",
      startedAt: 1_000,
      retry: { attempt: 2, of: 4, reason: "capacity" },
    },
    {
      id: "run",
      parent: null,
      name: "Run",
      kind: "Explore",
      task: "Inspect the project",
      state: "running",
      startedAt: 1_000,
      agents: { done: 2, started: 3, queued: 1 },
    },
  ];
  const section = subagentsSection(
    {
      open: true,
      agents,
      waiting: new Set(),
      sessions: [],
      language: "en",
      now: 2_000,
    },
    new NativeInfoActions(),
    t,
  )!;
  const retry = section.rows.find((row) => row.id === "agent:retry")!;
  const run = section.rows.find((row) => row.id === "agent:run")!;
  expect(retry.working).toBe(true);
  expect(retry.identityTone).toBe(agentTone("retry"));
  expect(run.identityTone).toBe(agentTone("run"));
  expect(retry.wave).toEqual(nativeInfoWave(0));
  expect(retry.help).toBe("Explore\nRetry the request");
  expect(run.working).toBeUndefined();
  expect(run.wave).toEqual({ index: 1, periodMs: SESSION_INFO_WAVE_PERIOD_MS, stepMs: SESSION_INFO_WAVE_STEP_MS });
  expect(run.progress).toContain("2");
  expect(run.progress).toContain("3");
  expect(run.help).toBe("Explore\nInspect the project");
});

// Leo, 2026-11-02, on "15 running · 27 done" over "Running 0 / 1000 max" and rows "Running" for
// two hours: "but what's going on with these?"
test("a subagent quiet past the idle window reads Idle in its line and the head, and the limit line names started chats", () => {
  const now = 10 * 60_000;
  const agents: Subagent[] = [
    { id: "busy", parent: null, name: "Busy", state: "running", startedAt: 0, quietSince: now - 1_000 },
    { id: "open", parent: null, name: "Long call", state: "running", startedAt: 0 },
    {
      id: "quiet",
      parent: null,
      name: "Waits on its build",
      state: "running",
      startedAt: 0,
      quietSince: now - IDLE_AFTER_MS,
    },
    { id: "done", parent: null, name: "Done", state: "completed", startedAt: 0, endedAt: 1_000 },
  ];
  const section = subagentsSection(
    {
      open: true,
      agents,
      waiting: new Set(),
      sessions: [],
      language: "en",
      now,
      limits: { maxRunning: 1000, maxRunningSource: "settings" },
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.meta).toBe("2 running · 1 idle · 1 done");
  const row = (id: string) => section.rows.find((each) => each.id === `agent:${id}`)!;
  expect(row("busy").trailing).toEndWith("Running");
  expect(row("open").trailing).toEndWith("Running");
  expect(row("quiet").trailing).toEndWith("Idle");
  expect(row("quiet").wave).toBeUndefined();
  expect(row("quiet").tone).toBe("muted");
  expect(row("quiet").identityTone).toBe(agentTone("quiet"));
  expect(section.rows.find((each) => each.id === "limit")!.title).toBe("Started chats: 0 of 1000 at once");
});

test("a started chat waiting for a free slot is queued in the head, never done", () => {
  const section = subagentsSection(
    {
      open: true,
      agents: [],
      waiting: new Set(),
      sessions: [
        { sessionId: "run", title: "Run the suite", state: "running", createdAt: 1 },
        { sessionId: "held", title: "Audit the strings", state: "idle", waitsForSlot: true, createdAt: 2 },
        { sessionId: "ended", title: "Draft the notes", state: "idle", createdAt: 3 },
      ],
      limits: { maxRunning: 1, maxRunningSource: "session" },
      language: "en",
      now: 2_000,
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.meta).toBe("1 running · 1 queued · 1 done");
  expect(section.rows.find((row) => row.id === "limit")?.detail).toBe("1 queued");
});

test("native server rows keep the command plain and expose every named port", async () => {
  const opened: string[] = [];
  const section = tasksSection(
    {
      open: true,
      processes: [
        {
          id: "server",
          command: "npm run dev -- --port 3000 --port=4000",
          startedAt: 1_000,
          state: "running",
        },
      ],
      transcriptTasks: [],
      listed: true,
      scheduled: [],
      workflows: [],
      local: true,
      now: 2_000,
      onOpenUrl: (url) => opened.push(url),
    },
    new NativeInfoActions(),
    t,
  )!;
  const row = section.rows.find((item) => item.id === "server:server")!;
  expect(row.action).toBeUndefined();
  expect(row.buttons?.map((button) => button.label)).toEqual([
    t("sessionInfo.servers.open", { url: "http://localhost:3000" }),
    t("sessionInfo.servers.open", { url: "http://localhost:4000" }),
  ]);
  for (const button of row.buttons ?? []) {
    const actions = new NativeInfoActions();
    const action = tasksSection(
      {
        open: true,
        processes: [
          {
            id: "server",
            command: "npm run dev -- --port 3000 --port=4000",
            startedAt: 1_000,
            state: "running",
          },
        ],
        transcriptTasks: [],
        listed: true,
        scheduled: [],
        workflows: [],
        local: true,
        now: 2_000,
        onOpenUrl: (url) => opened.push(url),
      },
      actions,
      t,
    )!
      .rows.find((item) => item.id === "server:server")!
      .buttons!.find((item) => item.label === button.label)!.action;
    actions.run(action);
  }
  await Promise.resolve();
  expect(opened).toEqual(["http://localhost:3000", "http://localhost:4000"]);
});
