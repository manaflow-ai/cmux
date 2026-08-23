import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";

const AUTH = "test-auth-key";

const mac = {
  authKey: AUTH,
  account: "acct-1",
  deviceId: "mac-uuid-1",
  appIdentity: "dev.cmux",
} as const;

const macUpsert = {
  ...mac,
  kind: "mac" as const,
  name: "Studio",
  endpointKey: "aa".repeat(32),
  homeRelay: "https://usc1.relay.cmux.dev/",
};

const viewer = { authKey: AUTH, account: "acct-1", viewerDeviceId: "phone-uuid-1" };

describe("device registry (contract 9.6/9.7)", () => {
  beforeEach(() => {
    vi.stubEnv("REGISTRY_AUTH_KEY", AUTH);
    vi.useFakeTimers();
    vi.setSystemTime(1_000_000_000);
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  test("wrong auth key is refused by name", async () => {
    const t = convexTest(schema);
    await expect(
      t.mutation(api.registry.upsertDevice, { ...macUpsert, authKey: "nope" }),
    ).rejects.toThrow(/unauthorized/);
  });

  test("upsert -> online in the account's Mac list; snapshot shape", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);
    const macs = await t.query(api.registry.macsFor, viewer);
    expect(macs).toHaveLength(1);
    expect(macs[0]).toMatchObject({
      deviceId: "mac-uuid-1",
      name: "Studio",
      online: true,
      homeRelay: "https://usc1.relay.cmux.dev/",
    });
  });

  test("lease: beats keep it online; three missed beats flip it offline", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);

    // 80s later, still inside the lease: sweep flips nothing.
    vi.advanceTimersByTime(80_000);
    await t.mutation(internal.registry.sweep, {});
    expect((await t.query(api.registry.macsFor, viewer))[0].online).toBe(true);

    // A beat renews the lease.
    await t.mutation(api.registry.beat, mac);
    vi.advanceTimersByTime(80_000);
    await t.mutation(internal.registry.sweep, {});
    expect((await t.query(api.registry.macsFor, viewer))[0].online).toBe(true);

    // Silence past the lease: offline (grayed), NEVER removed.
    vi.advanceTimersByTime(95_000);
    await t.mutation(internal.registry.sweep, {});
    const macs = await t.query(api.registry.macsFor, viewer);
    expect(macs).toHaveLength(1);
    expect(macs[0].online).toBe(false);

    // Coming back is a transition too.
    await t.mutation(api.registry.beat, mac);
    expect((await t.query(api.registry.macsFor, viewer))[0].online).toBe(true);
  });

  test("sign-out is never lease-waited", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);
    await t.mutation(api.registry.signOut, mac);
    const macs = await t.query(api.registry.macsFor, viewer);
    expect(macs[0].online).toBe(false); // immediate, no sweep involved
  });

  test("visibility: a hidden Mac never reaches the excluded viewer's snapshot", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);
    await t.mutation(api.registry.setVisibility, {
      ...mac,
      hiddenFrom: ["phone-uuid-1"],
    });
    expect(await t.query(api.registry.macsFor, viewer)).toHaveLength(0);
    // A different phone still sees it.
    const other = { ...viewer, viewerDeviceId: "phone-uuid-2" };
    expect(await t.query(api.registry.macsFor, other)).toHaveLength(1);
  });

  test("revocation removes the row and its beats — the stolen-device handle", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);
    await t.mutation(api.registry.revoke, mac);
    expect(await t.query(api.registry.macsFor, viewer)).toHaveLength(0);
  });

  test("build identities are separate participants (contract 1.5)", async () => {
    const t = convexTest(schema);
    await t.mutation(api.registry.upsertDevice, macUpsert);
    await t.mutation(api.registry.upsertDevice, {
      ...macUpsert,
      appIdentity: "dev.cmux.internal",
      name: "Studio (internal)",
    });
    const macs = await t.query(api.registry.macsFor, viewer);
    expect(macs).toHaveLength(2);
    await t.mutation(api.registry.signOut, { ...mac, appIdentity: "dev.cmux.internal" });
    const after = await t.query(api.registry.macsFor, viewer);
    expect(after.find((m) => m.appIdentity === "dev.cmux.internal")?.online).toBe(false);
    expect(after.find((m) => m.appIdentity === "dev.cmux")?.online).toBe(true);
  });
});
