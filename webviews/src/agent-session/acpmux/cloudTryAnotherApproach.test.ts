import { describe, expect, test } from "bun:test";
import { tryAnotherApproach, type CloudForkRunsRequest } from "./cloudTryAnotherApproach";

describe("Cloud Try another approach", () => {
  test("starts one child at the selected checkpoint and leaves the parent unchanged", async () => {
    const parent = Object.freeze({ session: "parent-session", rows: ["turn-1", "turn-2"] });
    const request: CloudForkRunsRequest = {
      sourceMachine: "machine-parent",
      session: parent.session,
      harness: "claude",
      checkpoint: 3,
      parentLabel: "Parent Cloud chat",
    };
    const seen: CloudForkRunsRequest[] = [];
    const child = await tryAnotherApproach(request, async (fork) => {
      seen.push(fork);
      return { childSessionId: "child-session", parentLabel: fork.parentLabel, rows: parent.rows.slice(0, 1) };
    });

    expect(seen).toEqual([request]);
    expect(child).toMatchObject({ childSessionId: "child-session", rows: ["turn-1"], parentLabel: "Parent Cloud chat" });
    expect(parent).toEqual({ session: "parent-session", rows: ["turn-1", "turn-2"] });
  });
});
