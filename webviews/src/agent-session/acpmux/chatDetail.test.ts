// One chat detail ladder for every surface (Leo, 2026-11-01: "whatever stuff im capable of seeing
// and doing in the gui i should be able to do in the chief and likewise"): Messages, Normal, Thinking,
// Verbose. The filter and what each level opens are one module both the agent chat and Home
// Channels read (chatDetail.ts); the old Presentation and Transcript View keys keep reading.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import {
  CHAT_DETAILS,
  DETAIL_KEY,
  defaultDetailOf,
  detailFromLegacy,
  detailParts,
  detailRows,
  presentationOfDetail,
  transcriptViewOfDetail,
} from "./chatDetail";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...fields,
});

const user = row("user", "user", { text: "Fix it" });
const thought = row("thought", "thought", { text: "thinking" });
const tools = row("tools", "toolGroup");
const reply = row("reply", "assistant", { text: "Done." });
const permission = row("permission", "permission", { permission: { permissionId: "p", pending: true, options: [] } });
const question = row("question", "questionRecord", {
  question: { id: "q", source: { harness: "claude", session: "s" }, items: [], state: { kind: "pending" } },
});
const rows = [user, thought, tools, permission, question, reply];

describe("the ladder", () => {
  test("has four levels in order, Messages first", () => {
    expect(CHAT_DETAILS).toEqual(["messages", "normal", "thinking", "verbose"]);
    expect(DETAIL_KEY).toBe("agentPane.display.detail");
  });

  test("Messages keeps the speakers and every pending ask; tools and thoughts go", () => {
    expect(detailRows(rows, "messages")).toEqual([user, permission, question, reply]);
  });

  test("Normal, Thinking and Verbose keep every row", () => {
    for (const level of ["normal", "thinking", "verbose"] as const) expect(detailRows(rows, level)).toBe(rows);
  });

  test("pending questions and permission asks show at every level", () => {
    for (const level of CHAT_DETAILS) {
      const shown = detailRows(rows, level);
      expect(shown).toContain(permission);
      expect(shown).toContain(question);
    }
  });

  test("each level opens one more thing", () => {
    expect(detailParts("messages")).toEqual({ tools: false, thoughtsOpen: false, toolsOpen: false });
    expect(detailParts("normal")).toEqual({ tools: true, thoughtsOpen: false, toolsOpen: false });
    expect(detailParts("thinking")).toEqual({ tools: true, thoughtsOpen: true, toolsOpen: false });
    expect(detailParts("verbose")).toEqual({ tools: true, thoughtsOpen: true, toolsOpen: true });
  });

  test("reads as the old presentation and transcript view the rows still draw by", () => {
    expect(presentationOfDetail("messages")).toBe("messages");
    expect(presentationOfDetail("verbose")).toBe("transcript");
    expect(transcriptViewOfDetail("thinking")).toBe("thinking");
    expect(transcriptViewOfDetail("messages")).toBe("normal");
  });
});

describe("migration from the two old keys", () => {
  test("presentation messages reads as Messages, whatever the transcript view", () => {
    expect(detailFromLegacy("messages", "verbose")).toBe("messages");
    expect(detailFromLegacy("messages", undefined)).toBe("messages");
  });

  test("otherwise the old transcript view carries over", () => {
    expect(detailFromLegacy("transcript", "thinking")).toBe("thinking");
    expect(detailFromLegacy(undefined, "verbose")).toBe("verbose");
    expect(detailFromLegacy(undefined, undefined)).toBeUndefined();
    expect(detailFromLegacy("bubbles", "loud")).toBeUndefined();
  });

  test("the default setting: the new key wins, else the old keys, else Normal", () => {
    expect(defaultDetailOf({})).toBe("normal");
    expect(defaultDetailOf({ "agentPane.display.presentation": "messages" })).toBe("messages");
    expect(defaultDetailOf({ "agentPane.display.transcriptView": "verbose" })).toBe("verbose");
    expect(
      defaultDetailOf({
        "agentPane.display.presentation": "messages",
        "agentPane.display.transcriptView": "verbose",
      }),
    ).toBe("messages");
    expect(
      defaultDetailOf({ "agentPane.display.detail": "thinking", "agentPane.display.presentation": "messages" }),
    ).toBe("thinking");
    expect(defaultDetailOf({ "agentPane.display.detail": "loud" })).toBe("normal");
  });
});
