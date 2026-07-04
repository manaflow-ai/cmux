import { describe, expect, mock, test } from "bun:test";

import { getOrCreateTenantForTeam } from "../services/subrouter/tenants";

const secret = Buffer.alloc(32, 9).toString("base64");

describe("subrouter tenants service", () => {
  test("creates one tenant mapping and reuses it on later calls", async () => {
    const db = createFakeTenantDb();
    const createTenant = mock(async (input: unknown) => ({
      id: "tenant-1",
      name: (input as { name: string }).name,
      key: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));
    const client = {
      createTenant,
      rotateTenant: mock(),
      revokeTenant: mock(),
      listAccounts: mock(),
      createAccount: mock(),
      deleteAccount: mock(),
    };

    const first = await getOrCreateTenantForTeam(
      db as never,
      "team-a",
      "Team A",
      { client: client as never, tenantKeySecret: secret },
    );
    const second = await getOrCreateTenantForTeam(
      db as never,
      "team-a",
      "Team A",
      { client: client as never, tenantKeySecret: secret },
    );

    expect(first).toEqual(second);
    expect(createTenant).toHaveBeenCalledTimes(1);
    expect(db.rows[0].tenantId).toBe("tenant-1");
    expect(db.rows[0].tenantName).toBe("Team A");
    expect(db.rows[0].encryptedTenantKey).not.toContain("srt_");
  });

  test("revokes the upstream tenant when the mapping insert fails", async () => {
    const db = createFakeTenantDb();
    db.insertError = new Error("insert failed");
    const createTenant = mock(async () => ({
      id: "tenant-orphan",
      name: "Team A",
      key: "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    }));
    const revokeTenant = mock(async () => {});
    const client = {
      createTenant,
      rotateTenant: mock(),
      revokeTenant,
      listAccounts: mock(),
      createAccount: mock(),
      deleteAccount: mock(),
    };

    await expect(
      getOrCreateTenantForTeam(
        db as never,
        "team-a",
        "Team A",
        { client: client as never, tenantKeySecret: secret },
      ),
    ).rejects.toThrow("insert failed");

    expect(revokeTenant).toHaveBeenCalledTimes(1);
    expect(revokeTenant).toHaveBeenCalledWith("tenant-orphan");
    expect(db.rows).toHaveLength(0);
  });
});

function createFakeTenantDb() {
  const rows: Array<{
    teamId: string;
    tenantId: string;
    tenantName: string;
    encryptedTenantKey: string;
  }> = [];

  const db = {
    rows,
    insertError: null as Error | null,
    transaction: async <T>(callback: (tx: unknown) => Promise<T>): Promise<T> => {
      const tx = {
        execute: async () => [],
        select: () => ({
          from: () => ({
            where: () => ({
              limit: async () => rows.slice(0, 1),
            }),
          }),
        }),
        insert: () => ({
          values: async (row: (typeof rows)[number]) => {
            if (db.insertError) throw db.insertError;
            rows.push(row);
          },
        }),
      };
      return await callback(tx);
    },
  };
  return db;
}
