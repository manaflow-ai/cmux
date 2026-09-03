import { describe, expect, test } from "bun:test";
import { decodeClientControl } from "../src/protocol";

describe("close_session control", () => {
  test("accepts a host close_session", () => {
    const decoded = decodeClientControl({ t: "close_session", sessionId: 4 });
    expect(decoded._tag).toBe("Right");
    if (decoded._tag !== "Right") return;
    expect(decoded.right.t).toBe("close_session");
  });

  test("rejects a non-integer session id", () => {
    expect(decodeClientControl({ t: "close_session", sessionId: "4" })._tag).toBe("Left");
    expect(decodeClientControl({ t: "close_session", sessionId: 1.5 })._tag).toBe("Left");
  });
});
