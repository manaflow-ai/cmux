import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { groupAgentMessages } from "./waitingMessages";

function message(id: string, name = "claude-sr2", text = id): AcpmuxRow {
  return {
    id,
    version: 1,
    at: 1,
    kind: "user",
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
    untyped: true,
  };
}

test("keeps one received message as its ordinary row", () => {
  const one = message("m1");
  expect(groupAgentMessages([one])).toEqual([one]);
});

test("folds consecutive received messages into one reusable card row", () => {
  const rows = [message("m1"), message("m2"), message("m3")];
  const [fold] = groupAgentMessages(rows);
  expect(fold?.kind).toBe("waitingMessages");
  expect(fold?.waiting).toEqual({ delivery: "chat", rows });
  expect(fold?.joined).toEqual(["m1", "m2", "m3"]);
  expect(fold?.text).toBe("m1\n\nm2\n\nm3");
  expect(groupAgentMessages(rows, [fold!])[0]).toBe(fold);
});

test("a non-message row ends a fold and the next run starts independently", () => {
  const first = message("m1");
  const second = message("m2");
  const third = message("m3");
  const assistant: AcpmuxRow = { id: "answer", version: 1, at: 1, kind: "assistant", text: "done" };
  const result = groupAgentMessages([first, second, assistant, third, message("m4")]);
  expect(result.map((row) => row.id)).toEqual(["messages-m1", "answer", "m3"]);
  expect(result[0]?.joined).toEqual(["m1", "m2"]);
  expect(result[2]?.waiting?.rows.map((row) => row.id)).toEqual(["m3", "m4"]);
});

