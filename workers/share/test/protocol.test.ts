import { describe, expect, test } from "bun:test";
import { allowedClientType, isOrderedHostStreamType, parseClientEnvelope } from "../src/protocol";
import { normalizedChat, parseMessage, validPointerPayload } from "../src/validate";

describe("share protocol", () => {
  test("pending viewers cannot send workspace, cursor, chat, or text frames", () => {
    for (const type of [
      "workspace.snapshot",
      "presence.pointer",
      "chat.message",
      "terminal.input",
      "textbox.operation",
    ]) {
      expect(allowedClientType("viewer", false, type)).toBe(false);
    }
    expect(allowedClientType("viewer", false, "pong")).toBe(true);
  });

  test("viewers cannot publish host-owned workspace frames after approval", () => {
    expect(allowedClientType("viewer", true, "workspace.snapshot")).toBe(false);
    expect(allowedClientType("viewer", true, "textbox.operation")).toBe(true);
    expect(allowedClientType("viewer", true, "terminal.input")).toBe(true);
    expect(allowedClientType("host", true, "workspace.snapshot")).toBe(true);
    expect(allowedClientType("host", true, "terminal.vt")).toBe(true);
    expect(allowedClientType("host", true, "terminal.grid")).toBe(false);
    expect(allowedClientType("host", true, "share.end")).toBe(true);
    expect(allowedClientType("viewer", true, "share.end")).toBe(false);
  });

  test("marks dependent terminal patches as reconnect-required when relay delivery is interrupted", () => {
    expect(isOrderedHostStreamType("terminal.vt")).toBe(true);
    expect(isOrderedHostStreamType("panel.frame")).toBe(false);
  });

  test("rejects malformed and oversized envelopes before dispatch", () => {
    expect(parseClientEnvelope({ v: 2, type: "pong", seq: 1, payload: {} })).toBeNull();
    expect(parseClientEnvelope({ v: 1, type: "pong", seq: -1, payload: {} })).toBeNull();
    const tooLarge = JSON.stringify({
      v: 1,
      type: "chat.message",
      seq: 1,
      payload: { text: "x".repeat(70 * 1_024) },
    });
    expect(parseMessage(tooLarge)).toBeNull();
  });

  test("normalizes chat and validates normalized workspace coordinates", () => {
    expect(normalizedChat("  hello\u0000 there  ")).toBe("hello there");
    expect(normalizedChat("x".repeat(501))).toBeNull();
    expect(validPointerPayload({ x: 0.25, y: 1, layoutRevision: 3, targetId: "pane-a" })).toBe(true);
    expect(validPointerPayload({ x: 1.1, y: 0, layoutRevision: 3 })).toBe(false);
  });
});
