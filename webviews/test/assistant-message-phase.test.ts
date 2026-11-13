// l10n-allow-file: test fixture replies, not shipped UI.
import { expect, test } from "bun:test";
import { fakeClient, records, settle } from "./support/fakeAcpmuxClient";
import { turnViewFrom, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const CHAT = "assistant-phase";
const chunk = (messageId: string, text: string, phase?: unknown) => ({
  method: "session/update",
  params: {
    update: {
      sessionUpdate: "agent_message_chunk",
      messageId,
      content: { type: "text", text },
      ...(phase !== undefined && { _meta: { codex: { phase } } }),
    },
  },
});
const event = (messageId: string, text: string, phase?: unknown): [string, string, Record<string, unknown>] => [
  "in",
  "agent_message_chunk",
  chunk(messageId, text, phase),
];
const opening: [string, string, Record<string, unknown>][] = [
  ["mux", "user_message", { text: "Check the code", promptId: "prompt", turnId: "turn" }],
  ["mux", "turn_started", { turnId: "turn", promptId: "prompt" }],
];

for (const live of [false, true])
  test(`assistant phases survive ${live ? "live chunks" : "history replay"} without leaking to another message`, async () => {
    const steps = [
      event("commentary", "Checking the code. ", "commentary"),
      event("commentary", "Reading the caller."),
      event("answer", "The fix is ready. ", "final_answer"),
      event("answer", "Tests pass."),
      event("unannotated", "A reply from another harness."),
      event("unknown", "A future phase.", "future_phase"),
    ];
    const daemon = await fakeClient(records(CHAT, [...opening, ...(live ? [] : steps)]));
    try {
      if (live) {
        daemon.push(steps);
        await settle();
      }
      const replies = daemon.rows().filter((row) => row.kind === "assistant");
      expect(replies.map((row) => [row.text, row.assistantPhase])).toEqual([
        ["Checking the code. Reading the caller.", "commentary"],
        ["The fix is ready. Tests pass.", "final_answer"],
        ["A reply from another harness.", undefined],
        ["A future phase.", undefined],
      ]);
    } finally {
      daemon.client.close();
    }
  });

test("a phase-only chunk updates its message and is retained when text follows", async () => {
  const daemon = await fakeClient(records(CHAT, opening));
  try {
    daemon.push([event("answer", "", "final_answer")]);
    await settle();
    const pending = daemon.rows().find((row) => row.kind === "assistant");
    expect(pending?.assistantPhase).toBe("final_answer");
    daemon.push([event("answer", "The fix is ready.")]);
    await settle();
    const replies = daemon.rows().filter((row) => row.kind === "assistant");
    expect(replies).toHaveLength(1);
    expect(replies[0]).toMatchObject({ id: pending!.id, text: "The fix is ready.", assistantPhase: "final_answer" });
  } finally {
    daemon.client.close();
  }
});

test("a phase-only correction preserves accumulated text and invalid phases do not replace it", async () => {
  const daemon = await fakeClient(records(CHAT, [...opening, event("answer", "The fix is ready.", "commentary")]));
  try {
    const before = daemon.rows().find((row) => row.kind === "assistant")!;
    daemon.push([event("answer", "", "final_answer"), event("answer", " Tests pass.", 42)]);
    await settle();
    const reply = daemon.rows().find((row) => row.kind === "assistant")!;
    expect(reply).toMatchObject({
      id: before.id,
      text: "The fix is ready. Tests pass.",
      assistantPhase: "final_answer",
    });
    expect(reply.version).toBeGreaterThan(before.version);
  } finally {
    daemon.client.close();
  }
});

test("a late phase-only update annotates its original message without interrupting the current one", async () => {
  const daemon = await fakeClient(
    records(CHAT, [...opening, event("earlier", "Earlier narration."), event("current", "The fix is ")]),
  );
  try {
    daemon.push([event("earlier", "", "commentary"), event("current", "ready.", "final_answer")]);
    await settle();
    const replies = daemon.rows().filter((row) => row.kind === "assistant");
    expect(replies.map((row) => [row.text, row.assistantPhase])).toEqual([
      ["Earlier narration.", "commentary"],
      ["The fix is ready.", "final_answer"],
    ]);
    expect(replies[0]?.streaming).toBe(false);
  } finally {
    daemon.client.close();
  }
});

test("the completed summary retains the actual turn start after the live clock clears", async () => {
  const history = records(CHAT, [...opening, event("answer", "The fix is ready.", "final_answer")]);
  const daemon = await fakeClient(history);
  try {
    daemon.push([["mux", "turn_result", { turnId: "turn", status: "completed" }]]);
    await settle();
    expect(daemon.rows().find((row) => row.kind === "turnSummary")?.turnStartedAtMs).toBe(history[1]!.at);
    expect(daemon.snapshot().turnStartedAtMs).toBeUndefined();
  } finally {
    daemon.client.close();
  }
});

test("an intervening turn_end does not change the frozen work duration", async () => {
  const history = records(CHAT, [
    ...opening,
    event("progress", "Checking the caller.", "commentary"),
    event("answer", "The fix is ready.", "final_answer"),
  ]);
  const daemon = await fakeClient(history);
  try {
    const duration = () =>
      turnViewFrom(daemon.rows(), new Set(), { working: daemon.snapshot().isWorking }).rows.find(
        (row) => row.kind === WORKED,
      )?.durationMs;
    const reply = daemon.rows().find((row) => row.assistantPhase === "final_answer")!;
    expect(reply.turnStartedAtMs).toBe(history[1]!.at);
    expect(duration()).toBe(2_000);
    daemon.push([["mux", "turn_end", { turnId: "turn" }]]);
    await settle();
    expect(duration()).toBe(2_000);
    daemon.push([["mux", "turn_result", { turnId: "turn", status: "completed" }]]);
    await settle();
    const final = daemon.rows().find((row) => row.assistantPhase === "final_answer")!;
    expect(final.turnStartedAtMs).toBe(reply.turnStartedAtMs);
    expect(duration()).toBe(2_000);
  } finally {
    daemon.client.close();
  }
});
