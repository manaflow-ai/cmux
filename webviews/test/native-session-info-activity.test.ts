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
  expect(retry.wave).toEqual(nativeInfoWave(0));
  expect(retry.help).toBe("Explore\nRetry the request");
  expect(run.working).toBeUndefined();
  expect(run.wave).toEqual({ index: 1, periodMs: SESSION_INFO_WAVE_PERIOD_MS, stepMs: SESSION_INFO_WAVE_STEP_MS });
  expect(run.progress).toContain("2");
  expect(run.progress).toContain("3");
  expect(run.help).toBe("Explore\nInspect the project");
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
