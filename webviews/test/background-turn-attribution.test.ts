// l10n-allow-file: test fixture prompts, commands and helper names, not shipped UI.
// A background turn's one quiet line cites what started it: the helper that ran the task, and the
// task's own command as it was typed, raw (Leo, 2026-11-05: "cite the helper/add atribution (like
// how ive gradually pushed for more andd more of that a la deeplinks and communicating in acpmux)
// and display the actual code in the raw or something"). acpmux names the task's call (`cause.origin`);
// the page finds that call, or the shell's own background update when the call is a helper's.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { BackgroundTurnLine } from "../src/agent-session/acpmux/conversation/BackgroundTurnLine";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SubagentNavContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

// These pin the line look (backgroundTurnLook.experiment.ts `line`): the default draws a background
// turn's calls inline, with no line (backgroundTurnInline.test.ts).
beforeAll(() => {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "background-turn-look": "line" };
});
afterAll(() => {
  globalThis.cmuxExperiments = undefined;
});

const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const shellCall = (id: string, command: string): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: command,
    kind: "execute",
    status: "completed",
    rawInput: { command, description: "Run the suite", run_in_background: true },
  }),
];
const weighed = (id: string, cause: Record<string, unknown>): Step => [
  "mux",
  "background_turn",
  { state: "started", id, trigger: "task_notification", cause },
];
const ended = (id: string): Step => [
  "mux",
  "background_turn",
  { state: "ended", id, trigger: "task_notification", quiet: true, reason: "result" },
];
const lineOf = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set()).find((row) => row.kind === BACKGROUND_TURN && row.background !== undefined)!;
// In the pane, as App.tsx provides it: a helper's name opens its transcript.
const html = (row: AcpmuxRow) =>
  renderToStaticMarkup(
    createElement(
      SubagentNavContext.Provider,
      { value: () => {} },
      createElement(BackgroundTurnLine, { row, expanded: false, onToggle: () => {} }),
    ),
  );

test("a background turn's line shows the raw command of the task that started it", async () => {
  const command = "cargo test -p acpmux --lib -- background_cause";
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh1", command),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-f", {
        kind: "shell",
        status: "failed",
        weight: "failure",
        origin: "sh1",
        summary: "Background command failed (exit code 101)",
      }),
      say("."),
      ended("bg-f"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = lineOf(rows());
    expect(line.background?.source).toEqual({ command });
    const drawn = html(line);
    expect(drawn).toContain("Background command failed (exit code 101)");
    // The command as typed, in the code face, not its description.
    expect(drawn).toContain(`<code class="cv-background-turn__command">${command}</code>`);
    expect(drawn).not.toContain("Run the suite");
  } finally {
    client.close();
  }
});

test("a helper's shell names that helper on the line, which opens it", async () => {
  // A subagent's own Bash call is not in the chat's transcript: acpmux's update for the shell
  // names the helper that started it.
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Look into the flaky test", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      // Tagged as the helper's own update, which goes to its subagent before the chat's rows.
      [
        "in",
        "background_task_update",
        {
          method: "session/update",
          params: {
            _meta: { acpmux: { subagent: "agent-explore-1" } },
            update: {
              sessionUpdate: "background_task_update",
              toolCallId: "toolu_step",
              command: "bun test test/flaky.test.ts",
              state: "failed",
              subagentSessionId: "agent-explore-1",
              subagentTitle: "Explore flaky test",
            },
          },
        },
      ],
      weighed("bg-s", {
        kind: "subagent_step",
        status: "failed",
        weight: "failure",
        origin: "toolu_step",
        summary: "Background command failed (exit code 1)",
      }),
      say("."),
      ended("bg-s"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = lineOf(rows());
    expect(line.background?.source).toEqual({
      command: "bun test test/flaky.test.ts",
      ownerId: "agent-explore-1",
      ownerTitle: "Explore flaky test",
    });
    const drawn = html(line);
    expect(drawn).toContain("Explore flaky test");
    expect(drawn).toContain('data-deeplink="#subagent:agent-explore-1"');
    expect(drawn).toContain(`<code class="cv-background-turn__command">bun test test/flaky.test.ts</code>`);
  } finally {
    client.close();
  }
});

test("a turn with no named task keeps its plain line", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Check back later", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      ["mux", "background_turn", { state: "started", id: "bg-w", trigger: "scheduled" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = lineOf(rows());
    expect(line.background?.source).toBeUndefined();
    expect(html(line)).not.toContain("<code");
  } finally {
    client.close();
  }
});

const shellUpdate = (toolCallId: string, command: string, state: string, owner?: [string, string]): Step => [
  "in",
  "background_task_update",
  update({
    sessionUpdate: "background_task_update",
    toolCallId,
    command,
    state,
    ...(owner && { subagentSessionId: owner[0], subagentTitle: owner[1] }),
  }),
];
const sources = (rows: AcpmuxRow[]) =>
  rows.filter((row) => row.kind === BACKGROUND_TURN).map((row) => row.background?.source);

test("every line a task's ends started is cited when its update comes after them", async () => {
  // A monitor's ticks each start a turn for the same call; the helper's update names it later.
  const tick = { kind: "monitor", status: "completed", weight: "silent", origin: "toolu_watch" };
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Watch CI", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-1", tick),
      ended("bg-1"),
      weighed("bg-2", tick),
      ended("bg-2"),
      shellUpdate("toolu_watch", "gh run watch 42", "running", ["agent-ci", "CI watcher"]),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const cited = { command: "gh run watch 42", ownerId: "agent-ci", ownerTitle: "CI watcher" };
    expect(sources(rows())).toEqual([cited, cited]);
  } finally {
    client.close();
  }
});

test("a reused call id starts a new task that inherits nothing of the last one", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run both", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      shellUpdate("call-1", "bun test a", "failed", ["agent-a", "Helper A"]),
      weighed("bg-a", { kind: "shell", status: "failed", weight: "failure", origin: "call-1" }),
      ended("bg-a"),
      shellUpdate("call-1", "bun test b", "running"),
      shellUpdate("call-1", "bun test b", "failed"),
      weighed("bg-b", { kind: "shell", status: "failed", weight: "failure", origin: "call-1" }),
      ended("bg-b"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    expect(sources(rows())).toEqual([
      { command: "bun test a", ownerId: "agent-a", ownerTitle: "Helper A" },
      { command: "bun test b" },
    ]);
  } finally {
    client.close();
  }
});
