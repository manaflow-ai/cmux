import { describe, expect, test } from "bun:test";
import { applySupersededMessage, diffCounts, mergeEventRecords, normalizeCatalog, permissionFromMessage, removeQueuedPrompt, settleOptimisticPrompt, toolOutput } from "./direct";
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

  test("drops the abandoned assistant row on a superseded message", () => {
    const rows = new Map<string, AcpmuxRow>([["assistant-1", { id: "assistant-1", version: 1, at: 1, kind: "assistant", text: "partial" }]]);
    const messageRows = new Map([["old-message", "assistant-1"]]);
    const superseded = new Set<string>();
    applySupersededMessage(rows, messageRows, superseded, "old-message");
    expect(rows.has("assistant-1")).toBe(false);
    expect(superseded.has("old-message")).toBe(true);
  });

  test("merges model options from the daemon model catalog", () => {
    const catalog = normalizeCatalog({ defaultHarness: "claude", harnesses: { claude: { family: "claude" } } }, { harnesses: [{ harness: "claude", models: [{ id: "sonnet", name: "Sonnet" }] }] });
    expect(catalog).toEqual([{ id: "claude", name: "claude", models: [{ id: "sonnet", name: "Sonnet" }] }]);
  });

  test("counts replacement lines in edited-file diffs", () => {
    expect(diffCounts({ content: [{ type: "diff", oldText: "old line", newText: "new line" }] })).toEqual({ additions: 1, deletions: 1 });
  });

  test("preserves nested raw tool output", () => {
    expect(toolOutput({ rawOutput: { content: [{ type: "text", text: "command result" }] } })).toBe("command result");
    expect(toolOutput({ rawOutput: { formatted_output: "formatted result" } })).toBe("formatted result");
    expect(toolOutput({ output: "x".repeat(5000) })).toHaveLength(4000);
  });

  test("removes a queued prompt when its user message starts", () => {
    expect(removeQueuedPrompt([{ id: "p1", prompt: "run it" }, { id: "p2", prompt: "later" }], "p1", "run it")).toEqual([{ id: "p2", prompt: "later" }]);
    expect(removeQueuedPrompt([{ id: "p1", prompt: "same" }, { id: "p2", prompt: "same" }], "p1", "same")).toEqual([{ id: "p2", prompt: "same" }]);
  });
});
