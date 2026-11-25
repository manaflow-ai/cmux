import { describe, expect, test } from "bun:test";
import { subagentListing } from "./listedSubagents";

describe("subagentListing", () => {
  test("reads acpmux's answer and leaves out what it cannot read", () => {
    const listing = subagentListing({
      running: [
        { id: "a", parent: null, title: "Helper", state: "running", background: true, startedAt: 5 },
        { id: "", state: "running" },
        { id: "b", state: "lost" },
      ],
      ended: [{ id: "c", parent: "a", state: "failed", background: false, kind: "workflow", endedAt: 9 }],
      endedOmitted: 3,
      seen: 120,
    });
    expect(listing.running).toEqual([
      {
        id: "a",
        parent: null,
        title: "Helper",
        state: "running",
        background: true,
        kind: undefined,
        toolCallId: undefined,
        startedAt: 5,
        endedAt: undefined,
      },
    ]);
    expect(listing.ended[0]).toMatchObject({ id: "c", parent: "a", state: "failed", kind: "workflow", endedAt: 9 });
    expect(listing.endedOmitted).toBe(3);
    expect(listing.seen).toBe(120);
  });

  test("a malformed answer is an empty list", () => {
    expect(subagentListing(null)).toEqual({ running: [], ended: [], endedOmitted: 0, seen: 0 });
  });
});
