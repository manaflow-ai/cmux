import { describe, expect, test } from "bun:test";
import {
  MAX_TERMINAL_VT_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  selectedTerminalTargetsFromWorkspacePayload,
  validPointerPayload,
  validResyncPayload,
  validTextOperationPayload,
  validTextSelectionPayload,
  validTerminalInputPayload,
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
    expect(validTerminalVTPayload({ ...payload, columns: 1_000, rows: 200 })).toBe(true);
    expect(validTerminalVTPayload({ ...payload, columns: 1_000, rows: 201 })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, kind: "delta" })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, dataB64: "***=" })).toBe(false);
    expect(validTerminalVTPayload({ ...payload, participant: {} })).toBe(false);

    const maximumDataB64 = "AAAA".repeat(MAX_TERMINAL_VT_BYTES / 3);
    expect(validTerminalVTPayload({ ...payload, dataB64: maximumDataB64 })).toBe(true);
    expect(validTerminalVTPayload({ ...payload, dataB64: `${maximumDataB64}AAAA` })).toBe(false);
  });

  test("accepts only bounded terminal text and known keys for an exact surface and revision", () => {
    const base = {
      surfaceId: "72C552A7-8F75-4DF3-AC47-3750D01D0C18",
      layoutRevision: 7,
    };
    expect(validTerminalInputPayload({ ...base, kind: "text", data: "echo hello" })).toBe(true);
    expect(validTerminalInputPayload({ ...base, kind: "key", data: "enter" })).toBe(true);
    expect(validTerminalInputPayload({ ...base, kind: "key", data: "ctrl-c" })).toBe(true);
    expect(validTerminalInputPayload({ ...base, kind: "text", data: "\n" })).toBe(false);
    expect(validTerminalInputPayload({ ...base, kind: "text", data: "🙂".repeat(MAX_TERMINAL_INPUT_BYTES / 4 + 1) })).toBe(false);
    expect(validTerminalInputPayload({ ...base, kind: "key", data: "command-enter" })).toBe(false);
    expect(validTerminalInputPayload({ ...base, kind: "key", data: "enter", participant: {} })).toBe(false);
    expect(validTerminalInputPayload({ ...base, surfaceId: "terminal", kind: "key", data: "enter" })).toBe(false);
  });

  test("derives terminal input membership from selected surfaces in every split", () => {
    const selectedA = "72C552A7-8F75-4DF3-AC47-3750D01D0C18";
    const hiddenA = "3C819442-134F-486E-8CB8-D408FA65A549";
    const selectedB = "8489FC65-5D32-4012-8200-6FC9DAB557B5";
    const browser = "CB3ABF39-47FE-4196-A01D-1B2E286B153C";
    expect(selectedTerminalTargetsFromWorkspacePayload({ scene: {
      layoutRevision: 12,
      panes: [
        {
          id: "left",
          selectedSurfaceId: selectedA,
          surfaces: [
            { id: hiddenA, kind: "terminal" },
            { id: selectedA, kind: "textbox" },
          ],
        },
        {
          id: "right",
          selectedSurfaceId: selectedB,
          surfaces: [{ id: selectedB, kind: "terminal" }],
        },
        {
          id: "bottom",
          selectedSurfaceId: browser,
          surfaces: [{ id: browser, kind: "browser" }],
        },
      ],
    } })).toEqual({ layoutRevision: 12, surfaceIds: [selectedA, selectedB] });

    expect(selectedTerminalTargetsFromWorkspacePayload({ scene: {
      layoutRevision: 12,
      panes: [{
        id: "left",
        selectedSurfaceId: selectedA,
        surfaces: [{ id: hiddenA, kind: "terminal" }],
      }],
    } })).toBeNull();
  });
});
