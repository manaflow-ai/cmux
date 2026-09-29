import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { vmCapabilitiesFor } from "../services/vms/drivers";
import {
  buildVmSyncRequest,
  publishVmOps,
  publishVmRowsById,
  publishVmSync,
  vmSyncOpForRow,
  vmSyncRecordFromRow,
  vmSyncReplaceOp,
  vmSyncTeamId,
  withVmSyncPublication,
  type VmSyncOp,
  type VmSyncPublisherDeps,
} from "../services/vms/presencePublisher";
import type { CloudVmRow, VmRepositoryShape } from "../services/vms/repository";

const T0 = new Date("2026-09-29T12:00:00.000Z");

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-a",
    billingTeamId: "team-1",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "vm-1",
    displayName: "Build box",
    slug: "sleepy-teal-otter",
    imageId: "devbox",
    imageVersion: "3",
    status: "running",
    idempotencyKey: null,
    createdAt: new Date(T0.getTime() - 60_000),
    updatedAt: T0,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: { networkIpv4: "10.0.0.5", networkIpv6: "fd00::5" },
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    ...overrides,
  };
}

/** Deps that run scheduled work inline and record every publication. */
function recordingDeps(rows: Record<string, CloudVmRow | null>) {
  const published: Array<{ teamId: string; ops: readonly VmSyncOp[] }> = [];
  const pending: Promise<void>[] = [];
  const deps: VmSyncPublisherDeps = {
    readRow: async (id) => rows[id] ?? null,
    publish: async (teamId, ops) => { published.push({ teamId, ops }); },
    schedule: (work) => { pending.push(work()); },
  };
  return { deps, published, settle: () => Promise.all(pending) };
}

describe("vm sync record shape", () => {
  test("mirrors the GET /api/vm entry and carries the row clock", () => {
    const record = vmSyncRecordFromRow(row());
    expect(record).toEqual({
      id: "vm-1",
      provider: "freestyle",
      status: "running",
      image: "devbox",
      imageVersion: "3",
      kind: "desktop",
      capabilities: vmCapabilitiesFor("freestyle"),
      createdAt: T0.getTime() - 60_000,
      displayName: "Build box",
      slug: "sleepy-teal-otter",
      createdByUserId: "user-a",
      address: { ipv4: "10.0.0.5", ipv6: "fd00::5" },
      sourceUpdatedAtMs: T0.getTime(),
    });
    expect(vmSyncRecordFromRow(row({ providerVmId: null }))).toBeNull();
    expect(vmSyncRecordFromRow(row({ providerMetadata: {} }))?.address).toEqual({ ipv4: null, ipv6: null });
  });

  test("team scope is the list's ownerTeamId with the runtime fallback", () => {
    expect(vmSyncTeamId(row())).toBe("team-1");
    expect(vmSyncTeamId(row({ ownerTeamId: "", billingTeamId: null }))).toBe("user-a");
    expect(vmSyncTeamId(row({ ownerTeamId: " ", billingTeamId: "team-2" }))).toBe("team-2");
  });

  test("a destroyed row publishes a delete, a listed row an upsert, no id nothing", () => {
    expect(vmSyncOpForRow(row({ status: "destroyed" }))).toEqual({
      kind: "delete",
      id: "vm-1",
      sourceUpdatedAtMs: T0.getTime(),
    });
    expect(vmSyncOpForRow(row({ status: "failed" }))?.kind).toBe("upsert");
    expect(vmSyncOpForRow(row({ providerVmId: null, status: "failed" }))).toBeNull();
  });

  test("replace carries the observed list and observation time", () => {
    const op = vmSyncReplaceOp([{
      providerVmId: "vm-1",
      provider: "freestyle",
      image: "devbox",
      imageVersion: null,
      status: "paused",
      createdAt: 1,
      updatedAt: 2,
      displayName: null,
      slug: null,
      createdByUserId: "user-a",
      ownerTeamId: "team-1",
      addressIpv4: null,
      addressIpv6: null,
    }], 99);
    expect(op.kind).toBe("replace");
    if (op.kind !== "replace") return;
    expect(op.observedAtMs).toBe(99);
    expect(op.records.map((r) => [r.id, r.status, r.sourceUpdatedAtMs])).toEqual([["vm-1", "paused", 2]]);
  });
});

describe("vm sync request", () => {
  const ops: VmSyncOp[] = [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: 1 }];

  test("builds the backend-only Worker publication with the service secret only", async () => {
    const request = buildVmSyncRequest("team-1", ops, {
      baseURL: "https://presence.example.test/dev",
      publisherSecret: "v".repeat(64),
    });
    expect(request?.url).toBe("https://presence.example.test/v1/sync/vms");
    expect(request?.method).toBe("POST");
    expect(request?.headers.get("x-cmux-vms-publisher-secret")).toBe("v".repeat(64));
    expect(request?.headers.get("authorization")).toBeNull();
    expect(await request?.json()).toEqual({ teamId: "team-1", ops });
  });

  test("skips publication when unconfigured or empty", () => {
    expect(buildVmSyncRequest("team-1", ops, { baseURL: "https://presence.example.test" })).toBeNull();
    expect(buildVmSyncRequest("team-1", ops, { publisherSecret: "v".repeat(64) })).toBeNull();
    expect(buildVmSyncRequest("team-1", [], { baseURL: "https://x.test", publisherSecret: "v".repeat(64) })).toBeNull();
    expect(buildVmSyncRequest("", ops, { baseURL: "https://x.test", publisherSecret: "v".repeat(64) })).toBeNull();
  });

  test("publishVmSync never throws on a rejected or failing publication", async () => {
    // Unconfigured env: resolves without I/O.
    await expect(publishVmSync("team-1", ops, async () => { throw new Error("must not be called"); })).resolves.toBeUndefined();
  });
});

describe("withVmSyncPublication", () => {
  const vmId = "00000000-0000-4000-8000-000000000001";
  const baseVmId = "00000000-0000-4000-8000-000000000002";

  function fakeRepository(calls: string[]): VmRepositoryShape {
    const ok = <A,>(name: string, value: A) => Effect.sync(() => { calls.push(name); return value; });
    const shape: Partial<VmRepositoryShape> = {
      markCreateRunning: (input) => ok("markCreateRunning", row({ id: input.id })),
      markBaseCreateRunning: (input) => ok("markBaseCreateRunning", row({ id: input.vmId })),
      markCreateFailed: () => ok("markCreateFailed", true),
      markBaseCreateFailed: () => ok("markBaseCreateFailed", true),
      markCreateAbandoned: (input) => ok("markCreateAbandoned", { vm: row({ id: input.id }), isBase: false }),
      resolveCreateCleanup: () => ok("resolveCreateCleanup", true),
      markProviderObservedStatus: () => ok("markProviderObservedStatus", true),
      reservePausedResume: (input) => ok("reservePausedResume", row({ id: input.id })),
      setDisplayName: () => ok("setDisplayName", true),
      markDestroyed: () => ok("markDestroyed", undefined),
      mergeProviderMetadata: () => ok("mergeProviderMetadata", undefined),
      // Non-list writes must pass through untouched.
      recordUsageEvent: () => ok("recordUsageEvent", undefined),
    };
    return shape as VmRepositoryShape;
  }

  test("each list-relevant write publishes the re-read row once with the right op", async () => {
    const calls: string[] = [];
    const rows: Record<string, CloudVmRow | null> = {
      [vmId]: row({ id: vmId }),
      [baseVmId]: row({ id: baseVmId, providerVmId: "vm-base", ownerTeamId: "team-2", status: "provisioning" }),
    };
    const { deps, published, settle } = recordingDeps(rows);
    const repo = withVmSyncPublication(fakeRepository(calls), deps);
    const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

    await run(repo.markCreateRunning({ id: vmId, providerVmId: "vm-1", image: "devbox" }));
    await run(repo.markBaseCreateRunning({ baseId: "b", generation: 1, vmId: baseVmId, providerVmId: "vm-base", image: "devbox", userId: "user-a" }));
    await run(repo.markCreateFailed({ id: vmId, code: "c", message: "m" }));
    await run(repo.markBaseCreateFailed({ baseId: "b", generation: 1, vmId: baseVmId, userId: "user-a", code: "c", message: "m" }));
    await run(repo.markCreateAbandoned!({ id: vmId, before: T0, now: T0, code: "c", message: "m" }));
    await run(repo.resolveCreateCleanup!({ id: vmId, providerVmId: "vm-1", leaseId: "l" }));
    await run(repo.markProviderObservedStatus({ id: vmId, providerVmId: "vm-1", status: "paused" }));
    await run(repo.reservePausedResume({ id: vmId, userId: "user-a", providerVmId: "vm-1", maxActiveVms: null }));
    await run(repo.setDisplayName({ id: vmId, displayName: "x" }));
    await run(repo.mergeProviderMetadata!({ id: vmId, patch: { networkIpv4: "10.0.0.9" } }));
    // Destroyed: the re-read row is gone from the list, so a delete goes out.
    rows[vmId] = row({ id: vmId, status: "destroyed", updatedAt: new Date(T0.getTime() + 1) });
    await run(repo.markDestroyed(vmId));
    await run(repo.recordUsageEvent({} as never));
    await settle();

    expect(calls).toEqual([
      "markCreateRunning", "markBaseCreateRunning", "markCreateFailed", "markBaseCreateFailed",
      "markCreateAbandoned", "resolveCreateCleanup", "markProviderObservedStatus", "reservePausedResume",
      "setDisplayName", "mergeProviderMetadata", "markDestroyed", "recordUsageEvent",
    ]);
    // One publication per list-relevant write (11), each a single op.
    expect(published).toHaveLength(11);
    expect(published.every((p) => p.ops.length === 1)).toBe(true);
    const kinds = published.map((p) => [p.teamId, p.ops[0]?.kind, p.ops[0]?.kind === "delete" ? p.ops[0].id : (p.ops[0] as { record: { id: string } }).record.id]);
    expect(kinds).toEqual([
      ["team-1", "upsert", "vm-1"],
      ["team-2", "upsert", "vm-base"],
      ["team-1", "upsert", "vm-1"],
      ["team-2", "upsert", "vm-base"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "upsert", "vm-1"],
      ["team-1", "delete", "vm-1"],
    ]);
    const last = published[10]?.ops[0];
    expect(last).toEqual({ kind: "delete", id: "vm-1", sourceUpdatedAtMs: T0.getTime() + 1 });
  });

  test("a failed write publishes nothing and a row without provider id is skipped", async () => {
    const calls: string[] = [];
    const { deps, published, settle } = recordingDeps({ [vmId]: row({ id: vmId, providerVmId: null }) });
    const failing: VmRepositoryShape = {
      ...fakeRepository(calls),
      setDisplayName: () => Effect.fail(new Error("db down")) as never,
    };
    const repo = withVmSyncPublication(failing, deps);
    await expect(Effect.runPromise(repo.setDisplayName({ id: vmId, displayName: "x" }))).rejects.toThrow("db down");
    await Effect.runPromise(repo.markProviderObservedStatus({ id: vmId, providerVmId: "vm-1", status: "paused" }));
    await settle();
    expect(published).toEqual([]);
  });

  test("optional methods stay absent when the wrapped repository lacks them", () => {
    const calls: string[] = [];
    const { markCreateAbandoned: _a, resolveCreateCleanup: _b, mergeProviderMetadata: _c, ...rest } = fakeRepository(calls);
    const repo = withVmSyncPublication(rest as VmRepositoryShape, recordingDeps({}).deps);
    expect(repo.markCreateAbandoned).toBeUndefined();
    expect(repo.resolveCreateCleanup).toBeUndefined();
    expect(repo.mergeProviderMetadata).toBeUndefined();
  });
});

describe("publish helpers", () => {
  test("publishVmRowsById groups current rows by team and dedups ids", async () => {
    const a = row({ id: "a", providerVmId: "vm-a", ownerTeamId: "team-1" });
    const b = row({ id: "b", providerVmId: "vm-b", ownerTeamId: "team-2", status: "destroyed" });
    const { deps, published, settle } = recordingDeps({ a, b, gone: null });
    publishVmRowsById(["a", "b", "a", "gone"], deps);
    await settle();
    expect(published.map((p) => [p.teamId, p.ops.map((op) => op.kind)])).toEqual([
      ["team-1", ["upsert"]],
      ["team-2", ["delete"]],
    ]);
  });

  test("publishVmOps forwards prebuilt ops and skips empty batches", async () => {
    const { deps, published, settle } = recordingDeps({});
    publishVmOps("team-1", [], deps);
    publishVmOps("team-1", [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: 1 }], deps);
    await settle();
    expect(published).toEqual([{ teamId: "team-1", ops: [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: 1 }] }]);
  });
});
