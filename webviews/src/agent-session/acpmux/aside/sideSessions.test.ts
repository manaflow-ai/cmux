import { describe, expect, test } from "bun:test";
import type { AcpmuxSessionEntry } from "../sessionList";
import { isSideSession } from "./sideSessions";

const session = (sessionId: string, side?: boolean): AcpmuxSessionEntry => ({
  sessionId,
  ...(side === undefined ? {} : { side }),
});

describe("side session detection", () => {
  test("recognizes a locally-created session before its side tag arrives", () => {
    expect(isSideSession("side-1", [session("side-1")], new Set(["side-1"]))).toBe(true);
  });

  test("recognizes a tagged session and ignores unrelated chats", () => {
    expect(isSideSession("side-1", [session("side-1", true)], new Set())).toBe(true);
    expect(isSideSession("main", [session("side-1", true)], new Set())).toBe(false);
  });
});
