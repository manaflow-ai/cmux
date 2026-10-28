import { describe, expect, test } from "bun:test";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";

describe("session tracking metadata", () => {
  test("retains the session's area tag and reported stuck state through list normalization", () => {
    const entry = sessionEntry({
      sessionId: "session-one",
      name: "fixture-session",
      peer: "fixture-worker",
      tags: { area: "Search" },
      status: "running",
      state: "stuck",
      stuckReason: "Provider unavailable",
      pullRequests: ["https://github.com/example/project/pull/12"],
    });
    expect(entry).toMatchObject({
      area: "Search",
      trackingState: "stuck",
      stuckReason: "Provider unavailable",
      peer: "fixture-worker",
      pullRequestUrls: ["https://github.com/example/project/pull/12"],
    });
  });

  test("retains an explicit area without deriving one from a name or working folder", () => {
    expect(sessionEntry({ sessionId: "s", area: "Composer", tags: { area: "Search" } })).toMatchObject({
      area: "Composer",
    });
    expect(sessionEntry({ sessionId: "s", name: "search-worker", cwd: "/work/search" })).not.toHaveProperty(
      "area",
      "search",
    );
  });

  test("does not coerce invalid tracking metadata into display text", () => {
    expect(sessionEntry({ sessionId: "s", area: {}, tags: [], state: 42, stuckReason: false })).toMatchObject({
      area: undefined,
      trackingState: undefined,
      stuckReason: undefined,
    });
  });
});
