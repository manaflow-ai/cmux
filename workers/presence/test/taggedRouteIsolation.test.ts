import { describe, expect, it } from "bun:test";
import {
  applyBackupOps,
  listBackupSnapshot,
  type PairedMacBackupRecord,
} from "../src/syncPairedMacs";
import type { SyncStorage } from "../src/syncStorage";

const T0 = 1_750_000_000_000;
const MAC_ID = "shared-physical-mac";
const LEGACY_SCOPE_A = "ios:ZmVhdHVyZS1h";
const SCOPE_A = "ios:v2:ZmVhdHVyZS1h";
const SCOPE_B = "ios:v2:ZmVhdHVyZS1i";

class FakeStorage implements SyncStorage {
  private map = new Map<string, unknown>();

  async get<T>(key: string): Promise<T | undefined> {
    return this.map.get(key) as T | undefined;
  }

  async put<T>(keyOrEntries: string | Record<string, unknown>, value?: T): Promise<void> {
    if (typeof keyOrEntries === "string") {
      this.map.set(keyOrEntries, JSON.parse(JSON.stringify(value)));
      return;
    }
    for (const [key, entry] of Object.entries(keyOrEntries)) {
      this.map.set(key, JSON.parse(JSON.stringify(entry)));
    }
  }

  async delete(key: string): Promise<boolean> {
    return this.map.delete(key);
  }

  async list<T>(options: { prefix: string; limit?: number }): Promise<Map<string, T>> {
    const result = new Map<string, T>();
    const keys = [...this.map.keys()].filter((key) => key.startsWith(options.prefix)).sort();
    for (const key of keys) {
      if (options.limit !== undefined && result.size >= options.limit) break;
      result.set(key, this.map.get(key) as T);
    }
    return result;
  }
}

function record(host: string, port: number, lastSeenAt: number): PairedMacBackupRecord {
  return {
    macDeviceID: MAC_ID,
    displayName: "Studio",
    routes: [{ id: "route", kind: "tailscale", endpoint: { type: "host_port", host, port }, priority: 0 }],
    createdAt: T0,
    lastSeenAt,
    isActive: true,
  };
}

function endpoint(snapshot: Awaited<ReturnType<typeof listBackupSnapshot>>): unknown {
  return snapshot.records[0]?.routes[0];
}

describe("tagged paired-Mac route isolation", () => {
  it("does not expose a legacy seeded scope through the versioned scope", async () => {
    const storage = new FakeStorage();

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.9", 50900, T0) }],
      T0,
      LEGACY_SCOPE_A,
    );

    expect((await listBackupSnapshot(storage, "user-1", SCOPE_A)).records).toEqual([]);

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.1", 51001, T0 + 1) }],
      T0 + 1,
      SCOPE_A,
    );

    expect(endpoint(await listBackupSnapshot(storage, "user-1", LEGACY_SCOPE_A))).toEqual(
      record("100.64.0.9", 50900, T0).routes[0],
    );
    expect(endpoint(await listBackupSnapshot(storage, "user-1", SCOPE_A))).toEqual(
      record("100.64.0.1", 51001, T0 + 1).routes[0],
    );
  });

  it("keeps tags A and B isolated when B restarts on the same physical Mac", async () => {
    const storage = new FakeStorage();

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.9", 50900, T0) }],
      T0,
    );
    expect((await listBackupSnapshot(storage, "user-1", SCOPE_A)).records).toEqual([]);

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.1", 51001, T0 + 1) }],
      T0 + 1,
      SCOPE_A,
    );
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.2", 51002, T0 + 2) }],
      T0 + 2,
      SCOPE_B,
    );

    const aBeforeRestart = await listBackupSnapshot(storage, "user-1", SCOPE_A);
    expect(endpoint(aBeforeRestart)).toEqual(record("100.64.0.1", 51001, T0 + 1).routes[0]);

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.3", 52002, T0 + 3) }],
      T0 + 3,
      SCOPE_B,
    );

    const aAfterRestart = await listBackupSnapshot(storage, "user-1", SCOPE_A);
    const bAfterRestart = await listBackupSnapshot(storage, "user-1", SCOPE_B);
    expect(endpoint(aAfterRestart)).toEqual(record("100.64.0.1", 51001, T0 + 1).routes[0]);
    expect(endpoint(bAfterRestart)).toEqual(record("100.64.0.3", 52002, T0 + 3).routes[0]);

    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: MAC_ID, record: record("100.64.0.10", 53000, T0 + 4) }],
      T0 + 4,
    );
    expect(endpoint(await listBackupSnapshot(storage, "user-1"))).toEqual(
      record("100.64.0.10", 53000, T0 + 4).routes[0],
    );
    expect(endpoint(await listBackupSnapshot(storage, "user-1", SCOPE_A))).toEqual(
      record("100.64.0.1", 51001, T0 + 1).routes[0],
    );
  });
});
