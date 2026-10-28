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
  const rows: readonly AcpmuxRow[] = Object.freeze([message("m1"), message("m2"), message("m3")]);
  const grouped = groupAgentMessages(rows);
  const [fold] = grouped;
  expect(fold?.kind).toBe("waitingMessages");
  expect(fold?.waiting).toEqual({ delivery: "chat", rows });
  expect(fold?.joined).toEqual(["m1", "m2", "m3"]);
  expect(fold?.text).toBe("m1\n\nm2\n\nm3");
  expect(groupAgentMessages(rows, grouped)[0]).toBe(fold);
});

test("replaces a cached fold when a received message changes", () => {
  const first = message("m1");
  const previous = groupAgentMessages([first, message("m2")]);
  const updated = groupAgentMessages([first, message("m2", "claude-sr2", "updated")], previous);
  expect(updated[0]).not.toBe(previous[0]);
  expect(updated[0]?.text).toBe("m1\n\nupdated");
  expect(updated[0]?.version).toBe((previous[0]?.version ?? 0) + 1);
});

test("a non-message row ends a fold and the next run starts independently", () => {
  const first = message("m1");
  const second = message("m2");
  const third = message("m3");
  const assistant: AcpmuxRow = { id: "answer", version: 1, at: 1, kind: "assistant", text: "done" };
  const result = groupAgentMessages([first, second, assistant, third, message("m4")]);
  expect(result.map((row) => row.id)).toEqual(["messages-m1", "answer", "messages-m3"]);
  expect(result[0]?.joined).toEqual(["m1", "m2"]);
  expect(result[2]?.waiting?.rows.map((row) => row.id)).toEqual(["m3", "m4"]);
});
