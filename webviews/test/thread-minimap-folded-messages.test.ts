import { expect, test } from "bun:test";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { minimapTurns, MIN_PROMPTS } from "../src/agent-session/acpmux/threadMinimap/model";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const messages: AcpmuxRow[] = Array.from({ length: 12 }, (_, index) => ({
  id: `user-${index + 10}`,
  kind: "user",
  version: 1,
  at: 1000 + index,
  text: `Synthetic report ${index}`,
  incoming: {
    kind: "message",
    message: {
      name: `Worker ${index}`,
      sessionId: `worker-${index}`,
      text: `Synthetic report ${index}`,
      raw: `Synthetic report ${index}`,
    },
  },
}));

test("a long chat keeps every received-message rail identity when adjacent messages fold", () => {
  const shaped = turnView(messages, new Set());
  const before = minimapTurns(messages, "fixture");
  const after = minimapTurns(shaped, "fixture");
  console.log(
    JSON.stringify({
      input: messages.length,
      drawnKinds: shaped.map((row) => row.kind),
      before: before.ticks.length,
      after: after.ticks.length,
      threshold: MIN_PROMPTS,
    }),
  );
  expect(after.ticks.map((tick) => tick.id)).toEqual(before.ticks.map((tick) => tick.id));
  expect(after.turns.length).toBeGreaterThanOrEqual(MIN_PROMPTS);
});

test("folded message ticks keep sender, preview, and their visible parent layout target", () => {
  const shaped = turnView(messages, new Set());
  const parent = shaped.find((row) => row.waiting?.delivery === "chat")!;
  const result = minimapTurns(shaped, "fixture");
  expect(
    result.turns.map((turn) => ({
      id: turn.id,
      targetId: turn.targetId,
      sender: turn.sender,
      prompt: turn.prompt,
      index: turn.index,
    })),
  ).toEqual(
    messages.map((row, index) => ({
      id: row.id,
      targetId: parent.id,
      sender: `Worker ${index}`,
      prompt: row.text!,
      index: shaped.indexOf(parent),
    })),
  );
});

test("streaming after a stable message fold does not reread the folded history", () => {
  const many = Array.from({ length: 1200 }, (_, index) => ({
    ...messages[index % messages.length]!,
    id: `user-${index}`,
    at: 1000 + index,
  }));
  const shaped = turnView(
    [...many, { id: "answer", kind: "assistant", version: 1, at: 5000, text: "Streaming", streaming: true }],
    new Set(),
  );
  const parent = shaped.find((row) => row.waiting?.delivery === "chat")!;
  let reads = 0;
  const members = new Proxy(parent.waiting!.rows, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads++;
      return Reflect.get(target, key, receiver);
    },
  });
  const rows = shaped.map((row) => (row === parent ? { ...row, waiting: { ...row.waiting!, rows: members } } : row));
  let previous = minimapTurns(rows, "stream");
  for (let token = 0; token < 3; token++) {
    const next = [...previous.rows];
    next[next.length - 1] = { ...next[next.length - 1]!, text: `Streaming ${token}`, version: token + 2 };
    reads = 0;
    const result = minimapTurns(next, "stream", previous, { base: previous.rows, rows: next, from: next.length - 1 });
    expect(result.turns).toHaveLength(1200);
    expect(reads).toBeLessThanOrEqual(2);
    expect(result.ticks).toBe(previous.ticks);
    previous = result;
  }
});

test("regrouping or editing a folded sender rebuilds only current identities without losing human prompts", () => {
  const human: AcpmuxRow = { id: "user-human", kind: "user", version: 1, at: 1, text: "Human prompt" };
  const first = minimapTurns(turnView([human, ...messages], new Set()), "edit");
  const changed = messages.map((row, index) =>
    index === 4
      ? {
          ...row,
          version: 2,
          text: "Revised report",
          incoming: {
            kind: "message" as const,
            message: {
              ...(row.incoming?.kind === "message" ? row.incoming.message : { name: "", text: "", raw: "" }),
              name: "Revised worker",
              text: "Revised report",
            },
          },
        }
      : row,
  );
  const next = turnView([human, ...changed], new Set());
  const result = minimapTurns(next, "edit", first);
  expect(result.ticks).toHaveLength(13);
  expect(result.turns[0]!.sender).toBeUndefined();
  expect(result.turns[5]).toMatchObject({ id: messages[4]!.id, sender: "Revised worker", prompt: "Revised report" });
  expect(result.turns).toEqual(minimapTurns(next, "edit").turns);
});
