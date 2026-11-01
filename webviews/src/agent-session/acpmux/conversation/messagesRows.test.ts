import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { messagesRows } from "./messagesRows";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...fields,
});

describe("messagesRows", () => {
  test("keeps every user and assistant segment, including intermediate assistant text", () => {
    const user = row("user", "user", { text: "Please inspect the change" });
    const first = row("assistant-1", "assistant", { text: "I am checking the files." });
    const second = row("assistant-2", "assistant", { text: "The issue is in the parser." });
    const rows = [user, row("work", "activity"), first, row("thought", "thought"), second, row("footer", "worked")];

    expect(messagesRows(rows)).toEqual([user, first, second]);
  });

  test("drops tools, groups, runs, thoughts, and ordinary turn footers", () => {
    const rows = [
      row("activity", "activity"),
      row("group", "toolGroup"),
      row("run", "toolRun"),
      row("thought", "thought"),
      row("working", "working"),
      row("summary", "turnSummary", { status: "completed", durationMs: 1200 }),
      row("date", "date"),
      row("typing", "typing"),
      row("pending-tool", "activity", { permission: { permissionId: "p", pending: true, options: [] } }),
    ];

    expect(messagesRows(rows)).toEqual([]);
  });

  test("drops empty assistant placeholders", () => {
    const empty = row("empty", "assistant", { text: "  " });
    expect(messagesRows([empty])).toEqual([]);
  });

  test("keeps pending permission and question rows, but not their completed records", () => {
    const permission = row("permission", "permission", {
      permission: { permissionId: "p", pending: true, options: [] },
    });
    const question = row("question", "questionRecord", {
      question: {
        id: "q",
        source: { harness: "claude", session: "s" },
        items: [],
        state: { kind: "pending" },
      },
    });
    const answeredPermission = row("permission-done", "permissionRecord", {
      permission: { permissionId: "p2", pending: false, options: [] },
    });
    const answeredQuestion = row("question-done", "questionRecord", {
      question: {
        id: "q2",
        source: { harness: "claude", session: "s" },
        items: [],
        state: { kind: "answered", answer: { selections: {} } },
      },
    });

    expect(messagesRows([permission, question, answeredPermission, answeredQuestion])).toEqual([permission, question]);
  });

  test("keeps pending and failed prompts, but removes hidden bookkeeping prompts", () => {
    const pending = row("pending", "user", { pending: true, text: "Waiting to send" });
    const failed = row("failed", "user", { failed: true, text: "Retry this" });
    const steer = row("steer", "user", { steer: "waiting", text: "Also check the tests" });
    const hidden = row("hidden", "user", { incoming: { kind: "hidden" }, text: "", pending: true });
    const attachment = row("attachment", "user", { text: "", images: [{ id: "image", mimeType: "image/png" }] });

    expect(messagesRows([pending, failed, steer, hidden, attachment])).toEqual([pending, failed, steer, attachment]);
  });

  test("keeps error recovery controls while omitting successful summaries", () => {
    const resume = row("resume", "turnSummary", { status: "cancelled", resumable: true });
    const failed = row("failed-summary", "turnSummary", { status: "failed", error: "agent stopped" });
    const normal = row("normal", "turnSummary", { status: "completed", resumable: true, retryable: true });

    expect(messagesRows([resume, failed, normal])).toEqual([resume, failed]);
  });

  test("returns original rows and caches by source array identity", () => {
    const assistant = row("assistant", "assistant", { text: "Done" });
    const source = [assistant];
    const first = messagesRows(source);
    const second = messagesRows(source);

    expect(first).toBe(second);
    expect(first[0]).toBe(assistant);
  });
});
