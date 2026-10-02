import { describe, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";
import { MockAcpmuxSocket, mockHost, mockReply } from "./mock";
import type { AcpmuxSnapshot } from "./model";

describe("mock transport", () => {
  /// Mock mode runs the real client against the in-page daemon, so a mock turn goes through the
  /// same event folding as an agent's.
  test("a prompt streams a scripted turn through the real client", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const client = await AcpmuxDirectClient.connect(mockHost, (snapshot) => snapshots.push(snapshot), undefined, () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket);
    client.snapshot();
    expect(snapshots.at(-1)?.rows.map((row) => row.kind)).toEqual(["assistant"]);
    expect(snapshots.at(-1)?.summary?.harness).toBe("claude");
    expect((await client.harnesses()).map((harness) => harness.id)).toEqual(["claude", "codex"]);

    await client.send("hello");
    for (let tries = 0; tries < 20 && !snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary"); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    const rows = snapshots.at(-1)!.rows;
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    expect(rows.find((row) => row.kind === "user")?.text).toBe("hello");
    expect(rows.filter((row) => row.kind === "assistant").at(-1)?.text).toContain(mockReply("hello"));
    // The turn edits files, so it has changes to review.
    const diffs = rows.flatMap((row) => row.items ?? []).flatMap((item) => item.tool?.diffs ?? []);
    expect(diffs.map((diff) => diff.path)).toEqual(["/mock/project/src/greeting.ts", "/mock/project/NOTES.md"]);
    client.close();
  });
});
