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

  test("projects existing silent-turn state and removes it when progress resumes", () => {
    const session = { sessionId: "quiet", status: "running", turn: { stalledSince: 123 } };
    expect(sessionEntry(session).stuck?.reason).toBe("silent");
    expect(sessionEntry({ ...session, turn: { stalledSince: null } }).stuck).toBeUndefined();
  });

  test("does not retain attention for closed or stopping sessions", () => {
    const session = { sessionId: "ended", state: "stuck", stuckReason: "loop", turn: { stalledSince: 123 } };
    expect(sessionEntry({ ...session, status: "closed" }).stuck).toBeUndefined();
    expect(sessionEntry({ ...session, state: "stopping" }).stuck).toBeUndefined();
  });

  test("cleared and malformed loop episodes do not mark a running row", () => {
    const session = { sessionId: "recovered", status: "running", turn: {} };
    expect(sessionEntry({ ...session, loopEpisode: null }).stuck).toBeUndefined();
    expect(sessionEntry({ ...session, loopEpisode: { diagnosis: "old" } }).stuck).toBeUndefined();
    expect(sessionEntry({ ...session, loopEpisode: { episodeId: 1, since: 123, count: 3, diagnosis: "Repeated failure", hint: "Try another approach" } }).stuck?.reason).toBe("loop");
  });
});
