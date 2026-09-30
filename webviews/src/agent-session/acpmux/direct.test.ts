import { describe, expect, test } from "bun:test";
import { mergeEventRecords, permissionFromMessage, settleOptimisticPrompt } from "./direct";
import type { AcpmuxRow } from "./model";

describe("direct acpmux event helpers", () => {
  test("uses the permission notification envelope session id", () => {
    const permission = permissionFromMessage({
      sessionId: "selected",
      permissionId: "permission-1",
      request: {
        sessionId: "agent-request-id",
        toolCall: { title: "Run command", kind: "execute" },
        options: [{ optionId: "yes", name: "Allow", kind: "allow_once" }],
      },
    }, "selected");
    expect(permission?.permissionId).toBe("permission-1");
    expect(permission?.options[0]?.id).toBe("yes");
  });

  test("removes an optimistic prompt when mux records it", () => {
    const rows = new Map<string, AcpmuxRow>([["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }]]);
    const promptRows = new Map([["p1", "local-p1"]]);
    settleOptimisticPrompt(rows, promptRows, { promptId: "p1" });
    expect(rows.has("local-p1")).toBe(false);
    expect(promptRows.has("p1")).toBe(false);
  });

  test("merges attach pages with live events without dropping either", () => {
    const event = (seq: number) => ({ seq, at: seq, sessionId: "s", dir: "mux", kind: "status", msg: { status: "ready" } });
    expect(mergeEventRecords([event(1), event(2)], [event(2), event(3)]).map((item) => item.seq)).toEqual([1, 2, 3]);
  });

  test("reconciles older user messages by text when promptId is absent", () => {
    const rows = new Map<string, AcpmuxRow>([["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }]]);
    const promptRows = new Map([["p1", "local-p1"]]);
    const promptTexts = new Map([["p1", "hello"]]);
    const fallbackPromptId = [...promptTexts.entries()].find(([, value]) => value === "hello")?.[0];
    settleOptimisticPrompt(rows, promptRows, { promptId: fallbackPromptId, text: "hello" });
    expect(rows.has("local-p1")).toBe(false);
  });
});
