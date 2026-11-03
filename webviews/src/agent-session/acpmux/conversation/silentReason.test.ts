import { expect, test } from "bun:test";
import { readSilentReason, retrySilentTurn } from "./silentReason";

test("acpmux's reason is read as it says, and an unknown or missing one is none", () => {
  expect(readSilentReason({ kind: "capacity", attempt: 2, of: 10, detail: "529 overloaded" })).toEqual({
    kind: "capacity",
    attempt: 2,
    of: 10,
    detail: "529 overloaded",
  });
  expect(readSilentReason({ kind: "no_answer" })).toEqual({ kind: "no_answer" });
  expect(readSilentReason({ kind: "something_new" })).toBeUndefined();
  expect(readSilentReason(undefined)).toBeUndefined();
  // A count with no attempt says nothing.
  expect(readSilentReason({ kind: "retrying", of: 10 })).toEqual({ kind: "retrying" });
});

test("Retry asks acpmux to end the silent turn and send it again, only to the chat it was drawn for", async () => {
  const calls: unknown[] = [];
  const request = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    return { promptId: "p~resume-1" };
  };
  expect(await retrySilentTurn({ sessionId: "s1", reaches: () => true, request })).toBeUndefined();
  expect(calls).toEqual([["_acpmux/retry", { sessionId: "s1", silent: true }]]);
  expect(await retrySilentTurn({ sessionId: "s1", reaches: () => false, request })).toBeUndefined();
  expect(calls.length).toBe(1);
  const busy = async () => Promise.reject({ code: -32602, reason: "retry.busy" });
  expect(await retrySilentTurn({ sessionId: "s1", reaches: () => true, request: busy })).toBe("retry.busy");
  const old = async () => Promise.reject({ code: -32601, message: "Method not found" });
  expect(await retrySilentTurn({ sessionId: "s1", reaches: () => true, request: old })).toBe("retry.failed");
});
