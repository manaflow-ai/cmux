import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  STUCK_PROVISIONING_FAILURE_CODE,
  VmRepository,
  VmRepositoryLive,
  type VmRepositoryShape,
} from "../services/vms/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function repo<A, E>(use: (repository: VmRepositoryShape) => Effect.Effect<A, E>): Promise<A> {
  return Effect.runPromise(
    Effect.gen(function* () {
      const repository = yield* VmRepository;
      return yield* use(repository);
    }).pipe(Effect.provide(VmRepositoryLive)),
  );
}

async function truncateAll() {
  if (!sql) throw new Error("test database not initialized");
  await sql`truncate cloud_vm_credit_reservations, cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
}

async function insertVm(input: {
  readonly userId: string;
  readonly status: string;
  readonly providerVmId?: string | null;
  readonly updatedAt?: Date;
}): Promise<string> {
  if (!sql) throw new Error("test database not initialized");
  const updatedAt = input.updatedAt ?? new Date();
  const [row] = await sql<{ id: string }[]>`
    insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status, created_at, updated_at)
    values (${input.userId}, 'freestyle', ${input.providerVmId ?? null}, 'snapshot-test', ${input.status}, ${updatedAt}, ${updatedAt})
    returning id
  `;
  if (!row) throw new Error("vm insert returned no row");
  return row.id;
}

describe("VM repository status guards", () => {
  dbTest("markCreateRunning does not resurrect a destroyed row", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-guard-resurrect", status: "destroyed" });

    const error = await repo((repository) =>
      repository.markCreateRunning({
        id: vmId,
        providerVmId: "provider-vm-resurrect",
        image: "snapshot-test",
      }).pipe(Effect.flip),
    );
    expect(error._tag).toBe("VmDatabaseError");

    const [row] = await sql!<{ status: string; provider_vm_id: string | null }[]>`
      select status, provider_vm_id from cloud_vms where id = ${vmId}
    `;
    expect(row?.status).toBe("destroyed");
    expect(row?.provider_vm_id).toBeNull();
  });

  dbTest("markCreateRunning finalizes a provisioning row", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-guard-finalize", status: "provisioning" });

    const vm = await repo((repository) =>
      repository.markCreateRunning({
        id: vmId,
        providerVmId: "provider-vm-finalize",
        image: "snapshot-test",
      }),
    );
    expect(vm.status).toBe("running");
    expect(vm.providerVmId).toBe("provider-vm-finalize");
  });

  dbTest("markCreateFailed leaves a destroyed row destroyed", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-guard-failed", status: "destroyed" });

    await repo((repository) =>
      repository.markCreateFailed({ id: vmId, code: "provider_create", message: "late failure" }),
    );

    const [row] = await sql!<{ status: string }[]>`select status from cloud_vms where id = ${vmId}`;
    expect(row?.status).toBe("destroyed");
  });

  dbTest("recordLease conflict never un-revokes a revoked lease", async () => {
    await truncateAll();
    const vmId = await insertVm({
      userId: "user-guard-lease",
      status: "running",
      providerVmId: "provider-vm-lease",
    });
    const revokedAt = new Date();
    await sql!`
      insert into cloud_vm_leases (vm_id, user_id, kind, token_hash, transport, expires_at, revoked_at)
      values (${vmId}, 'user-guard-lease', 'pty', 'guard-lease-hash', 'websocket', ${new Date(Date.now() + 60_000)}, ${revokedAt})
    `;

    const error = await repo((repository) =>
      repository.recordLease({
        vmId,
        userId: "user-guard-lease",
        kind: "pty",
        tokenHash: "guard-lease-hash",
        expiresAt: new Date(Date.now() + 120_000),
      }).pipe(Effect.flip),
    );
    expect(error._tag).toBe("VmDatabaseError");

    const [row] = await sql!<{ revoked_at: Date | null }[]>`
      select revoked_at from cloud_vm_leases where token_hash = 'guard-lease-hash'
    `;
    expect(row?.revoked_at).not.toBeNull();
  });

  dbTest("recordLease conflict still refreshes an active lease", async () => {
    await truncateAll();
    const vmId = await insertVm({
      userId: "user-guard-lease-active",
      status: "running",
      providerVmId: "provider-vm-lease-active",
    });
    await sql!`
      insert into cloud_vm_leases (vm_id, user_id, kind, token_hash, transport, expires_at)
      values (${vmId}, 'user-guard-lease-active', 'pty', 'guard-lease-active-hash', 'websocket', ${new Date(Date.now() + 60_000)})
    `;

    const laterExpiry = new Date(Date.now() + 600_000);
    await repo((repository) =>
      repository.recordLease({
        vmId,
        userId: "user-guard-lease-active",
        kind: "pty",
        tokenHash: "guard-lease-active-hash",
        expiresAt: laterExpiry,
      }),
    );

    const [row] = await sql!<{ expires_at: Date; revoked_at: Date | null }[]>`
      select expires_at, revoked_at from cloud_vm_leases where token_hash = 'guard-lease-active-hash'
    `;
    expect(row?.revoked_at).toBeNull();
    expect(row?.expires_at.getTime()).toBe(laterExpiry.getTime());
  });
});

describe("stuck provisioning sweeper (repository)", () => {
  dbTest("fails only old provisioning rows without a provider VM id", async () => {
    await truncateAll();
    const old = new Date(Date.now() - 60 * 60 * 1000);
    const stuckId = await insertVm({ userId: "user-sweep", status: "provisioning", updatedAt: old });
    const recentId = await insertVm({ userId: "user-sweep", status: "provisioning" });
    const withProviderId = await insertVm({
      userId: "user-sweep",
      status: "provisioning",
      providerVmId: "provider-vm-sweep-live",
      updatedAt: old,
    });
    const runningId = await insertVm({
      userId: "user-sweep",
      status: "running",
      providerVmId: "provider-vm-sweep-running",
      updatedAt: old,
    });

    const swept = await repo((repository) =>
      repository.sweepStuckProvisioning!({
        olderThan: new Date(Date.now() - 30 * 60 * 1000),
        limit: 10,
      }),
    );

    expect(swept.map((row) => row.id)).toEqual([stuckId]);
    expect(swept[0]?.failureCode).toBe(STUCK_PROVISIONING_FAILURE_CODE);
    const rows = await sql!<{ id: string; status: string }[]>`
      select id, status from cloud_vms order by created_at
    `;
    const statusById = new Map(rows.map((row) => [row.id, row.status]));
    expect(statusById.get(stuckId)).toBe("failed");
    expect(statusById.get(recentId)).toBe("provisioning");
    expect(statusById.get(withProviderId)).toBe("provisioning");
    expect(statusById.get(runningId)).toBe("running");
  });
});

describe("credit reservation repository", () => {
  dbTest("insertCreditReservation is idempotent per VM row", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-reservation", status: "provisioning" });
    const input = {
      vmId,
      billingCustomerType: "team",
      billingCustomerId: "team-reservation",
      itemId: "cmux-vm-create-credit",
      amount: 1,
    };

    const first = await repo((repository) => repository.insertCreditReservation!(input));
    const second = await repo((repository) => repository.insertCreditReservation!(input));
    expect(second.id).toBe(first.id);

    const [{ count }] = await sql!<{ count: string }[]>`
      select count(*)::text as count from cloud_vm_credit_reservations where vm_id = ${vmId}
    `;
    expect(count).toBe("1");
  });

  dbTest("transitionCreditReservation only wins from an allowed state", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-reservation-transition", status: "provisioning" });
    const { id } = await repo((repository) =>
      repository.insertCreditReservation!({
        vmId,
        billingCustomerType: "team",
        billingCustomerId: "team-reservation-transition",
        itemId: "cmux-vm-create-credit",
        amount: 1,
      }),
    );

    const debited = await repo((repository) =>
      repository.transitionCreditReservation!({ id, from: ["pending"], to: "debited" }),
    );
    expect(debited).toBe(true);

    // Two actors race for the refund claim: exactly one wins.
    const claimA = await repo((repository) =>
      repository.transitionCreditReservation!({ id, from: ["debited"], to: "refunding" }),
    );
    const claimB = await repo((repository) =>
      repository.transitionCreditReservation!({ id, from: ["debited"], to: "refunding" }),
    );
    expect([claimA, claimB].filter(Boolean)).toHaveLength(1);
  });

  dbTest("staleCreditReservations returns unresolved rows with their VM", async () => {
    await truncateAll();
    const vmId = await insertVm({ userId: "user-reservation-stale", status: "failed" });
    const { id } = await repo((repository) =>
      repository.insertCreditReservation!({
        vmId,
        billingCustomerType: "team",
        billingCustomerId: "team-reservation-stale",
        itemId: "cmux-vm-create-credit",
        amount: 1,
      }),
    );
    await repo((repository) =>
      repository.transitionCreditReservation!({ id, from: ["pending"], to: "debited" }),
    );
    await sql!`
      update cloud_vm_credit_reservations
      set updated_at = ${new Date(Date.now() - 60 * 60 * 1000)}
      where id = ${id}
    `;

    const stale = await repo((repository) =>
      repository.staleCreditReservations!({
        olderThan: new Date(Date.now() - 15 * 60 * 1000),
        limit: 10,
      }),
    );
    expect(stale).toHaveLength(1);
    expect(stale[0]?.reservation.id).toBe(id);
    expect(stale[0]?.reservation.status).toBe("debited");
    expect(stale[0]?.vm?.id).toBe(vmId);
    expect(stale[0]?.vm?.status).toBe("failed");

    // Committed reservations are settled and never come back.
    await repo((repository) =>
      repository.transitionCreditReservation!({ id, from: ["debited"], to: "committed" }),
    );
    const settled = await repo((repository) =>
      repository.staleCreditReservations!({
        olderThan: new Date(),
        limit: 10,
      }),
    );
    expect(settled).toHaveLength(0);
  });
});
