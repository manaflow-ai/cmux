import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle, type SnapshotData } from "freestyle";
import { FreestyleProvider, FreestyleSnapshotNotFoundError, freestyleSnapshotRef } from "../services/vms/drivers/freestyle";
import { ProviderError } from "../services/vms/drivers/types";
import { isProviderNotFoundError } from "../services/vms/providerErrors";

// The Freestyle driver's snapshot inventory: `listSnapshots` reads the
// account's snapshots filtered to one source machine (`GET /v5/snapshots`),
// and `deleteSnapshot` deletes only a snapshot taken from the named machine.
// The SDK client is faked; the driver's mapping and guards are what is pinned.

function snapshot(overrides: Partial<SnapshotData> & { id: string }): SnapshotData {
  return {
    sourceVmId: "fs-1",
    slug: null,
    displayName: null,
    accountId: "acct",
    public: false,
    createdAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-01T00:00:00.000Z",
    ...overrides,
  };
}

function providerWith(snapshots: {
  list?: (options: { sourceVmId?: string; limit?: number; offset?: number }) => Promise<{ snapshots: SnapshotData[]; totalCount: number }>;
  get?: (snapshotId: string) => Promise<SnapshotData>;
  delete?: (snapshotId: string) => Promise<void>;
}) {
  const calls: { list: Array<Record<string, unknown>>; get: string[]; delete: string[] } = { list: [], get: [], delete: [] };
  const client = {
    vms: {
      snapshots: {
        list: async (options: { sourceVmId?: string; limit?: number; offset?: number }) => {
          calls.list.push(options);
          return snapshots.list ? snapshots.list(options) : { snapshots: [], totalCount: 0 };
        },
        get: async (snapshotId: string) => {
          calls.get.push(snapshotId);
          if (!snapshots.get) throw new Error("unexpected get");
          return snapshots.get(snapshotId);
        },
        delete: async (snapshotId: string) => {
          calls.delete.push(snapshotId);
          await snapshots.delete?.(snapshotId);
        },
      },
    },
  } as unknown as Freestyle;
  const provider = new FreestyleProvider({
    client: () => client,
    resolveDaemonSource: async () => {
      throw new Error("unused");
    },
  });
  return { provider, calls };
}

describe("FreestyleProvider.listSnapshots", () => {
  test("asks for the machine's snapshots and maps them newest first, label over slug", async () => {
    const { provider, calls } = providerWith({
      list: async () => ({
        snapshots: [
          snapshot({ id: "snap-old", slug: "nightly", createdAt: "2026-09-01T00:00:00.000Z" }),
          snapshot({ id: "snap-new", slug: "nightly-2", displayName: "before-upgrade", createdAt: "2026-09-03T00:00:00.000Z" }),
          snapshot({ id: "snap-bare", createdAt: "2026-09-02T00:00:00.000Z" }),
        ],
        totalCount: 3,
      }),
    });
    const listed = await provider.listSnapshots("fs-1");
    expect(calls.list).toEqual([{ sourceVmId: "fs-1", limit: 100, offset: 0 }]);
    expect(listed).toEqual([
      { id: "snap-new", createdAt: Date.parse("2026-09-03T00:00:00.000Z"), name: "before-upgrade" },
      { id: "snap-bare", createdAt: Date.parse("2026-09-02T00:00:00.000Z") },
      { id: "snap-old", createdAt: Date.parse("2026-09-01T00:00:00.000Z"), name: "nightly" },
    ]);
  });

  test("pages through a large inventory and never lists another machine's snapshot", async () => {
    const firstPage = Array.from({ length: 100 }, (_, index) => snapshot({ id: `snap-${index}`, createdAt: `2026-08-01T00:00:${String(index % 60).padStart(2, "0")}.000Z` }));
    const { provider, calls } = providerWith({
      list: async ({ offset }) => offset === 0
        ? { snapshots: firstPage, totalCount: 102 }
        : { snapshots: [snapshot({ id: "snap-100" }), snapshot({ id: "snap-foreign", sourceVmId: "fs-9" })], totalCount: 102 },
    });
    const listed = await provider.listSnapshots("fs-1");
    expect(calls.list.map((options) => options.offset)).toEqual([0, 100]);
    expect(listed).toHaveLength(101);
    expect(listed.some((entry) => entry.id === "snap-foreign")).toBe(false);
  });

  test("an unparseable timestamp maps to 0 rather than NaN, and an empty label is no name", () => {
    expect(freestyleSnapshotRef(snapshot({ id: "s", createdAt: "not-a-date", displayName: "  " }))).toEqual({ id: "s", createdAt: 0 });
  });

  test("a failing list is a provider error", async () => {
    const { provider } = providerWith({
      list: async () => {
        throw new FreestyleApiError(500, { code: "INTERNAL", message: "boom" }, "/v5/snapshots");
      },
    });
    await expect(provider.listSnapshots("fs-1")).rejects.toBeInstanceOf(ProviderError);
  });
});

describe("FreestyleProvider.deleteSnapshot", () => {
  test("deletes a snapshot taken from the named machine", async () => {
    const { provider, calls } = providerWith({
      get: async (id) => snapshot({ id }),
    });
    await provider.deleteSnapshot("fs-1", "snap-1");
    expect(calls.get).toEqual(["snap-1"]);
    expect(calls.delete).toEqual(["snap-1"]);
  });

  test("refuses a snapshot taken from another machine as not-found, without deleting", async () => {
    const { provider, calls } = providerWith({
      get: async (id) => snapshot({ id, sourceVmId: "fs-9" }),
    });
    let thrown: unknown;
    try {
      await provider.deleteSnapshot("fs-1", "snap-1");
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(ProviderError);
    expect((thrown as ProviderError).cause).toBeInstanceOf(FreestyleSnapshotNotFoundError);
    // What the workflow branches on: the wrapped error reads as "not found".
    expect(isProviderNotFoundError(thrown)).toBe(true);
    expect(calls.delete).toEqual([]);
  });

  test("a snapshot the provider no longer has is not-found; other failures are not", async () => {
    const missing = providerWith({
      get: async () => {
        throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "snapshot not found" }, "/v5/snapshots/snap-gone");
      },
    });
    let thrown: unknown;
    try {
      await missing.provider.deleteSnapshot("fs-1", "snap-gone");
    } catch (err) {
      thrown = err;
    }
    expect(isProviderNotFoundError(thrown)).toBe(true);
    expect(missing.calls.delete).toEqual([]);

    const broken = providerWith({
      get: async (id) => snapshot({ id }),
      delete: async () => {
        throw new FreestyleApiError(503, { code: "UNAVAILABLE", message: "try later" }, "/v5/snapshots/snap-1");
      },
    });
    let other: unknown;
    try {
      await broken.provider.deleteSnapshot("fs-1", "snap-1");
    } catch (err) {
      other = err;
    }
    expect(other).toBeInstanceOf(ProviderError);
    expect(isProviderNotFoundError(other)).toBe(false);
  });
});
