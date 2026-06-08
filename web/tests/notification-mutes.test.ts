import { describe, expect, test } from "bun:test";
import { readMutedWorkspaceIds } from "../services/apns/mutedWorkspaces";
import type { CloudDb } from "../db/client";

/// A minimal Drizzle-shaped stub: `select(...).from(...).where(...)` resolves to
/// the given rows, or throws to exercise the fail-open path.
function stubDb(
  result: { workspaceId: string }[] | (() => never),
): CloudDb {
  const where = () => {
    if (typeof result === "function") return result();
    return Promise.resolve(result);
  };
  return {
    select: () => ({ from: () => ({ where }) }),
  } as unknown as CloudDb;
}

describe("readMutedWorkspaceIds", () => {
  test("returns the user's muted workspace ids", async () => {
    const db = stubDb([{ workspaceId: "ws-a" }, { workspaceId: "ws-b" }]);
    const muted = await readMutedWorkspaceIds(db, "user-1");
    expect([...muted].sort()).toEqual(["ws-a", "ws-b"]);
  });

  test("fails open to an empty set when the lookup throws (e.g. table missing)", async () => {
    const db = stubDb(() => {
      throw new Error('relation "notification_workspace_mutes" does not exist');
    });
    const muted = await readMutedWorkspaceIds(db, "user-1");
    // Empty set => shouldDeliverToWorkspace stays true => existing behavior.
    expect(muted.size).toBe(0);
  });
});
