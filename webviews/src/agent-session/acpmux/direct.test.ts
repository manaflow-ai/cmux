import { describe, expect, test } from "bun:test";
import { permissionFromMessage, settleOptimisticPrompt } from "./direct";
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
});
