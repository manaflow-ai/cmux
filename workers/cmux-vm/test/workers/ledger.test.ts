/**
 * The per-tenant ledger behind the Durable Object: token buckets, quota
 * reservations and idempotency claims, with an explicit clock.
 */
import { describe, expect, it } from "vitest";
import { IDEMPOTENCY_LEASE_MS, IDEMPOTENCY_TTL_MS, memoryLedgerStorage, RESERVATION_TTL_MS, TenantLedger } from "../../src/limits/ledger.ts";

const ledger = () => new TenantLedger(memoryLedgerStorage());

describe("rate", () => {
  it("allows perMinute requests, then refuses with a retry hint, then refills", async () => {
    const l = ledger();
    const rule = { perMinute: 2 };
    expect(await l.rate("write", rule, 0)).toEqual({ ok: true });
    expect(await l.rate("write", rule, 0)).toEqual({ ok: true });
    expect(await l.rate("write", rule, 0)).toEqual({ ok: false, retryAfterSeconds: 30 });
    expect(await l.rate("read", rule, 0)).toEqual({ ok: true });
    expect(await l.rate("write", rule, 30_000)).toEqual({ ok: true });
  });
});

describe("reserve", () => {
  it("counts live resources plus creates in flight, and releases", async () => {
    const l = ledger();
    expect(await l.reserve("vm", 2, 1, 0, "r1")).toEqual({ ok: true, reservationId: "r1" });
    expect(await l.reserve("vm", 2, 1, 0, "r2")).toEqual({ ok: false });
    expect(await l.reserve("snapshot", 2, 1, 0, "r3")).toEqual({ ok: true, reservationId: "r3" });
    await l.release("r1");
    expect(await l.reserve("vm", 2, 1, 0, "r4")).toEqual({ ok: true, reservationId: "r4" });
  });

  it("lets a reservation whose create died lapse", async () => {
    const l = ledger();
    await l.reserve("vm", 1, 0, 0, "r1");
    expect(await l.reserve("vm", 1, 0, RESERVATION_TTL_MS - 1, "r2")).toEqual({ ok: false });
    expect(await l.reserve("vm", 1, 0, RESERVATION_TTL_MS, "r3")).toEqual({ ok: true, reservationId: "r3" });
  });
});

describe("idempotency", () => {
  it("claims, blocks concurrent use, rejects a different request, and replays when done", async () => {
    const l = ledger();
    expect(await l.begin("k", "f1", 0)).toEqual({ state: "new" });
    expect(await l.begin("k", "f1", 1)).toEqual({ state: "in_progress" });
    expect(await l.begin("k", "f2", 1)).toEqual({ state: "mismatch" });
    await l.advance("k", { phase: "done", vmId: "vm_x" }, 2);
    expect(await l.begin("k", "f1", 3)).toEqual({ state: "resume", progress: { phase: "done", vmId: "vm_x" } });
    expect(await l.begin("k", "f1", IDEMPOTENCY_TTL_MS + 1)).toEqual({ state: "new" });
  });

  it("forgets a failed claim with no progress, and keeps a fork's snapshot for one retry at a time", async () => {
    const l = ledger();
    await l.begin("plain", "f", 0);
    await l.abandon("plain", 1);
    expect(await l.begin("plain", "f", 2)).toEqual({ state: "new" });

    await l.begin("fork", "f", 0);
    await l.advance("fork", { phase: "snapshotted", snapshotId: "snap_x" }, 1);
    expect(await l.begin("fork", "f", 2)).toEqual({ state: "in_progress" });
    await l.abandon("fork", 3);
    expect(await l.begin("fork", "f", 4)).toEqual({ state: "resume", progress: { phase: "snapshotted", snapshotId: "snap_x" } });
    expect(await l.begin("fork", "f", 5)).toEqual({ state: "in_progress" });
  });

  it("releases a claim whose request died after its lease", async () => {
    const l = ledger();
    await l.begin("k", "f", 0);
    expect(await l.begin("k", "f", IDEMPOTENCY_LEASE_MS - 1)).toEqual({ state: "in_progress" });
    expect(await l.begin("k", "f", IDEMPOTENCY_LEASE_MS)).toEqual({ state: "new" });
  });
});
