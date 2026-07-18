import { describe, expect, test } from "bun:test";
import {
  validPointerPayload,
  validResyncPayload,
  validTextOperationPayload,
  validTextSelectionPayload,
} from "../src/validate";

const id = (clock: number, client: string) => `${String(clock).padStart(12, "0")}:${client}`;

describe("viewer collaboration payloads", () => {
  test("rejects caller-supplied participant identity", () => {
    expect(validPointerPayload({ x: 0, y: 1, layoutRevision: 2 })).toBe(true);
    expect(validPointerPayload({
      x: 0,
      y: 1,
      layoutRevision: 2,
      participant: { userId: "spoofed" },
    })).toBe(false);
    expect(validTextSelectionPayload({
      docId: "document",
      anchorUTF16: 0,
      headUTF16: 1,
      participant: { userId: "spoofed" },
    })).toBe(false);
  });

  test("bounds and validates replicated TextBox operations", () => {
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "viewer"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "viewer"), afterId: id(1, "host"), value: "🙂", deleted: false }],
      },
    }, "viewer")).toBe(true);
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "spoofed"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "spoofed"), afterId: null, value: "x", deleted: false }],
      },
    }, "viewer")).toBe(false);
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "viewer"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: "invalid", afterId: null, value: "x", deleted: false }],
      },
    })).toBe(false);
    expect(validTextOperationPayload({
      operation: {
        opId: "999999999999:viewer",
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "viewer"), afterId: null, value: "x", deleted: false }],
      },
    })).toBe(false);
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "viewer"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "viewer"), afterId: null, value: "x" }],
      },
    })).toBe(false);
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "viewer"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "viewer"), afterId: null, value: "👨‍👩‍👧‍👦", deleted: false }],
      },
    })).toBe(true);
    expect(validTextOperationPayload({
      operation: {
        opId: id(3, "viewer"),
        docId: "document",
        kind: "insert",
        atoms: [{ id: id(2, "viewer"), afterId: null, value: `e${"\u0301".repeat(32)}`, deleted: false }],
      },
    })).toBe(false);
  });

  test("accepts only a bounded resync reason", () => {
    expect(validResyncPayload({ reason: "terminal_sequence" })).toBe(true);
    expect(validResyncPayload({ reason: "x".repeat(65) })).toBe(false);
    expect(validResyncPayload({ reason: "ok", participant: {} })).toBe(false);
  });
});
