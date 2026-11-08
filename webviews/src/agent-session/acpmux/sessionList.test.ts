import { describe, expect, test } from "vitest";
import { sessionEntry } from "./sessionList";

describe("sessionEntry stuck state", () => {
  test("projects a loop diagnosis from the daemon summary", () => {
    const entry = sessionEntry({
      sessionId: "stuck-1",
      name: "codex",
      harness: "codex",
      cwd: "/tmp/project",
      status: "running",
      state: "stuck",
      stuckReason: "loop",
      stuckSince: 123,
      stuckError: "Repeated cargo test 3 times; the same call keeps failing",
    });
    expect(entry.stuck).toEqual({
      reason: "loop",
      since: 123,
      diagnosis: "Repeated cargo test 3 times; the same call keeps failing",
    });
  });

  test("does not mark a normal working session stuck", () => {
    expect(
      sessionEntry({ sessionId: "working-1", name: "codex", harness: "codex", cwd: "/tmp", status: "running" }).stuck,
    ).toBeUndefined();
  });
});
