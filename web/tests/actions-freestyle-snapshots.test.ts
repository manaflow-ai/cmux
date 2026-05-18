import { afterEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  FreestyleActionSnapshotLookupError,
  findFreestyleActionSnapshotByName,
} from "../services/actions/freestyleSnapshots";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("Freestyle action snapshot lookup", () => {
  test("uses the newest reusable snapshot and skips in-progress snapshots", async () => {
    globalThis.fetch = mock(async () =>
      new Response(JSON.stringify({
        snapshots: [
          {
            snapshotId: "snapshot-creating",
            name: "cmux-actions-cache",
            state: "creating",
            createdAt: "2026-05-18T12:00:00.000Z",
          },
          {
            snapshotId: "snapshot-ready",
            name: "cmux-actions-cache",
            state: "ready",
            createdAt: "2026-05-18T11:00:00.000Z",
          },
          {
            snapshotId: "snapshot-other",
            name: "other-cache",
            state: "ready",
            createdAt: "2026-05-18T13:00:00.000Z",
          },
        ],
      }), { status: 200 })) as unknown as typeof fetch;

    const result = await Effect.runPromise(findFreestyleActionSnapshotByName("cmux-actions-cache"));

    expect(result).toEqual({
      id: "snapshot-ready",
      name: "cmux-actions-cache",
      createdAt: "2026-05-18T11:00:00.000Z",
    });
  });

  test("returns a typed safe error when the provider request fails", async () => {
    globalThis.fetch = mock(async () =>
      new Response("upstream provider details should stay hidden", { status: 503 })) as unknown as typeof fetch;

    const result = await Effect.runPromise(Effect.either(findFreestyleActionSnapshotByName("cmux-actions-cache")));

    expect(result._tag).toBe("Left");
    if (result._tag !== "Left") throw new Error("expected lookup to fail");
    expect(result.left).toBeInstanceOf(FreestyleActionSnapshotLookupError);
    expect(String(result.left)).not.toContain("upstream provider details");
  });
});
