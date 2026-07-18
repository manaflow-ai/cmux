import { describe, expect, test } from "bun:test";
import {
  MAX_TERMINAL_VT_BYTES,
  validPointerPayload,
  validResyncPayload,
  validTextOperationPayload,
  validTextSelectionPayload,
  validTerminalVTPayload,
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

  test("strictly validates bounded terminal VT stream frames", () => {
    const payload = {
      surfaceId: "72C552A7-8F75-4DF3-AC47-3750D01D0C18",
      generation: 2,
      stateSeq: 4,
      columns: 120,
      rows: 40,
      kind: "patch",
      dataB64: "G1tI",
    };
    expect(validTerminalVTPayload(payload)).toBe(true);
    expect(validTerminalVTPayload({ ...payload, generation: 0 })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, stateSeq: Number.MAX_SAFE_INTEGER + 1 })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, columns: 1_001 })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, kind: "delta" })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, dataB64: "***=" })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, participant: {} })).toBe(false);

    const maximumDataB64 = "AAAA".repeat(MAX_TERMINAL_VT_BYTES / 3);
    expect(validTerminalVTPayload({ ...payload, dataB64: maximumDataB64 })).toBe(true);
    expect(validTerminalVTPayload({ ...payload, dataB64: `${maximumDataB64}AAAA` })).toBe(false);
  });
});
