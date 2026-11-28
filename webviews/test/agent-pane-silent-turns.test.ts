// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A turn something other than the person started that said nothing to them leaves the transcript for
// the composer hat (conversation/silentTurns.ts). Leo, 2026-11-25, on bare "Worked for 3s >" rows:
// "so... why were these 0 text output from you (is that a personal setting on my end)". One that did
// something with effects (an edit, a message, a PR landed) keeps its place, as does every turn the
// person started and every one that said something.
import { expect, test } from "bun:test";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { splitSilentTurns } from "../src/agent-session/acpmux/conversation/silentTurns";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const ran = (id: string, title = `gh run list ${id}`, kind = "execute"): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title,
    kind,
    status: "completed",
    rawInput: { command: title },
  }),
];
const personTurn = (text: string, reply: string, turnId: string): Step[] => [
  ["mux", "user_message", { text, turnId }],
  ["mux", "turn_started", { turnId }],
  say(reply),
  ["mux", "turn_result", { turnId, status: "completed" }],
];
const started = (id: string, trigger = "system"): Step => ["mux", "background_turn", { state: "started", id, trigger }];
const ended = (id: string, quiet: boolean, trigger = "system"): Step => [
  "mux",
  "background_turn",
  { state: "ended", id, trigger, quiet, reason: "result" },
];
const notified = (turnId: string, steps: Step[]): Step[] => [
  [
    "mux",
    "user_message",
    {
      text: "<task-notification><summary>Background command finished</summary></task-notification>",
      client: "adopt",
      turnId,
    },
  ],
  ["mux", "turn_started", { turnId }],
  ...steps,
  ["mux", "turn_result", { turnId, status: "completed" }],
];

async function split(steps: Step[], working = false) {
  const { client, rows } = await connect(fakeDaemon(record(steps)));
  try {
    return { all: rows(), ...splitSilentTurns(rows(), working) };
  } finally {
    client.close();
  }
}

test("a quiet background turn that only checked things goes to the hat", async () => {
  const { all, rows, silent } = await split([
    ...personTurn("Land it once CI passes", "Queued.", "t1"),
    started("bg1"),
    ran("a"),
    ran("b"),
    ended("bg1", true),
  ]);
  expect(silent).toHaveLength(1);
  expect(silent[0]).toMatchObject({
    background: { id: "bg1", trigger: "system" },
    steps: ["gh run list a", "gh run list b"],
  });
  expect(rows.some((row) => row.kind === BACKGROUND_TURN || row.inBackground === "bg1")).toBe(false);
  // The person's turn is untouched.
  expect(rows).toEqual(all.filter((row) => row.kind !== BACKGROUND_TURN && row.inBackground !== "bg1"));
  expect(rows.some((row) => row.text === "Queued.")).toBe(true);
});

test("a notification's turn with no reply goes to the hat; one with a reply stays", async () => {
  const quiet = await split([...personTurn("Watch it", "Watching.", "t1"), ...notified("t2", [ran("a")])]);
  expect(quiet.silent).toHaveLength(1);
  expect(quiet.silent[0]!.background).toBeUndefined();
  expect(quiet.rows.some((row) => row.turnId === "t2" || row.incoming?.kind === "notice")).toBe(false);

  const said = await split([
    ...personTurn("Watch it", "Watching.", "t1"),
    ...notified("t2", [ran("a"), say("It passed.")]),
  ]);
  expect(said.silent).toHaveLength(0);
  expect(said.rows).toBe(said.all);
});

test("a silent turn with effects keeps its place", async () => {
  for (const effect of [ran("e", "Edit src/a.ts", "edit"), ran("l", "glaeda-gh land manaflow-ai/cmux#1 --sha abc")]) {
    const { rows, all, silent } = await split([
      ...personTurn("Go", "On it.", "t1"),
      started("bg1"),
      effect,
      ended("bg1", true),
    ]);
    expect(silent).toHaveLength(0);
    expect(rows).toBe(all);
  }
});

test("the person's own turn with no reply, a running turn and a turn that said something stay", async () => {
  const person = await split([
    ["mux", "user_message", { text: "Check CI", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    ran("a"),
    ["mux", "turn_result", { turnId: "t1", status: "completed" }],
  ]);
  expect(person.silent).toHaveLength(0);

  const running = await split([...personTurn("Go", "On it.", "t1"), started("bg1"), ran("a")]);
  expect(running.silent).toHaveLength(0);

  const loud = await split([
    ...personTurn("Go", "On it.", "t1"),
    started("bg1"),
    ran("a"),
    say("The deploy failed: should I roll back?"),
    ended("bg1", false),
  ]);
  expect(loud.silent).toHaveLength(0);
});
