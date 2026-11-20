import { expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { revealedSourceReply, sourceReplyRows } from "./sourceReplyReveal";

const row = (id: string, kind = "assistant"): AcpmuxRow => ({ id, kind, version: 1, at: 1 });

test("source reply navigation decodes the raw segment, not a harness message id", () => {
  expect(revealedSourceReply("source-reply:turn.boot.2")).toEqual({ replyId: "turn.boot.2" });
  expect(revealedSourceReply('source-reply:{"replyId":"turn.boot.2","seq":42}')).toEqual({
    replyId: "turn.boot.2",
    seq: 42,
  });
  for (const value of ["message:turn.boot.2", "source-reply:", "source-reply:a\nb", `source-reply:${"x".repeat(201)}`])
    expect(revealedSourceReply(value)).toBeUndefined();
  for (const seq of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "42", null])
    expect(revealedSourceReply(`source-reply:${JSON.stringify({ replyId: "turn.boot.2", seq })}`)).toBeUndefined();
});

test("only the exact assistant segment can reveal; a later turn or same-turn segment never substitutes", () => {
  const rows = [row("assistant-turn.boot.1"), row("assistant-turn.boot.2"), row("assistant-later.boot.1")];
  expect(sourceReplyRows(rows, "turn.boot.2")).toEqual(["assistant-turn.boot.2"]);
  expect(sourceReplyRows(rows, "turn.boot.3")).toEqual([]);
  expect(sourceReplyRows([row("assistant-turn.boot.2", "user")], "turn.boot.2")).toEqual([]);
});
