import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
  type VmCreateCreditReservation,
} from "../services/vms/billingGateway";
import { VmBillingError, VmCreateCreditsInsufficientError, VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmCreditReservationRow,
  type CloudVmCreditReservationStatus,
  type CloudVmRow,
  type StaleCreditReservation,
  type VmRepositoryShape,
} from "../services/vms/repository";
import {
  createVm,
  reconcileCreditReservations,
  sweepStuckProvisioningVms,
} from "../services/vms/workflows";

type RecordedUsageEvent = Parameters<VmRepositoryShape["recordUsageEvent"]>[0];
type ReservationTransition = {
  readonly id: string;
  readonly from: readonly CloudVmCreditReservationStatus[];
  readonly to: CloudVmCreditReservationStatus;
};

const RESERVATION_ID = "00000000-0000-4000-8000-0000000000aa";

function vmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-credit-reservations",
    billingTeamId: "team-credit-reservations",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: null,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ...overrides,
  };
}

function stackReservation(): Exclude<VmCreateCreditReservation, { kind: "none" }> {
  return {
    kind: "stack_item",
    itemId: "cmux-vm-create-credit",
    customerType: "team",
    customerId: "team-credit-reservations",
    amount: 1,
  };
}

function reservationRow(
  overrides: Partial<CloudVmCreditReservationRow> = {},
): CloudVmCreditReservationRow {
  const now = new Date();
  return {
    id: RESERVATION_ID,
    vmId: "00000000-0000-4000-8000-000000000001",
    billingCustomerType: "team",
    billingCustomerId: "team-credit-reservations",
    itemId: "cmux-vm-create-credit",
    amount: 1,
    status: "debited",
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

function reservationRepo(input: {
  readonly vm: CloudVmRow;
  readonly calls?: string[];
  readonly transitions?: ReservationTransition[];
  readonly usageEvents?: RecordedUsageEvent[];
  readonly staleReservations?: StaleCreditReservation[];
  readonly sweepStuckProvisioning?: VmRepositoryShape["sweepStuckProvisioning"];
  readonly transitionResult?: (transition: ReservationTransition) => boolean;
}): VmRepositoryShape {
  const record = (name: string) => input.calls?.push(name);
  return {
    listUserVms: () => Effect.succeed([]),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    beginCreate: () => Effect.succeed({ inserted: true as const, vm: input.vm }),
    beginBaseOpen: () => Effect.die("beginBaseOpen unused"),
    beginBaseReset: () => Effect.die("beginBaseReset unused"),
    markBaseCreateRunning: () => Effect.die("markBaseCreateRunning unused"),
    markBaseCreateFailed: () => Effect.void,
    activeLimitCandidates: () => Effect.succeed([]),
    reservePausedResume: () => Effect.succeed(null),
    reconciliationCandidates: () => Effect.succeed([]),
    markProviderObservedStatus: () => Effect.succeed(true),
    setDisplayName: () => Effect.succeed(true),
    markCreateRunning: (update) =>
      Effect.sync(() => {
        record("markCreateRunning");
        return {
          ...input.vm,
          providerVmId: update.providerVmId,
          status: "running" as const,
        };
      }),
    markCreateFailed: () =>
      Effect.sync(() => {
        record("markCreateFailed");
      }),
    hasOwnedSnapshot: () => Effect.succeed(false),
    findUserVm: () => Effect.succeed(null),
    markDestroyed: () => Effect.void,
    recordLease: () => Effect.void,
    accountDeletionIdentityLeases: () => Effect.succeed([]),
    listVmSessions: () => Effect.succeed([]),
    upsertVmSession: () => Effect.die("upsertVmSession unused"),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    recordUsageEvent: (event) =>
      Effect.sync(() => {
        input.usageEvents?.push(event);
      }),
    recordUsageEvents: (events) =>
      Effect.sync(() => {
        input.usageEvents?.push(...events);
      }),
    insertCreditReservation: () =>
      Effect.sync(() => {
        record("insertCreditReservation");
        return { id: RESERVATION_ID };
      }),
    transitionCreditReservation: (transition) =>
      Effect.sync(() => {
        record(`transition:${transition.from.join("|")}->${transition.to}`);
        input.transitions?.push(transition);
        return input.transitionResult ? input.transitionResult(transition) : true;
      }),
    staleCreditReservations: () => Effect.succeed(input.staleReservations ?? []),
    sweepStuckProvisioning: input.sweepStuckProvisioning,
  };
}

function billingGateway(input: {
  readonly calls?: string[];
  readonly reserveError?: VmBillingError | VmCreateCreditsInsufficientError;
  readonly refundError?: VmBillingError;
  readonly refunds?: VmCreateCreditReservation[];
}): VmBillingGatewayShape {
  return {
    resolveInitialCreateCreditGrant: () => ({ kind: "none" }),
    applyCreateCreditGrant: () => Effect.void,
    resolveCreateCredit: () => stackReservation(),
    reserveCreate: () =>
      Effect.suspend(() => {
        input.calls?.push("reserveCreate");
        return input.reserveError
          ? Effect.fail(input.reserveError)
          : Effect.succeed<VmCreateCreditReservation>(stackReservation());
      }),
    refundCreate: (reservation) =>
      Effect.suspend(() => {
        input.calls?.push("refundCreate");
        input.refunds?.push(reservation);
        return input.refundError ? Effect.fail(input.refundError) : Effect.void;
      }),
  };
}

function providerGateway(input: { readonly createError?: VmProviderOperationError } = {}): VmProviderGatewayShape {
  return {
    create: () =>
      input.createError
        ? Effect.fail(input.createError)
        : Effect.succeed({
          providerVmId: "provider-vm-1",
          provider: "freestyle" as const,
          image: "snapshot-test",
          status: "running" as const,
          createdAt: Date.now(),
        }),
    destroy: () => Effect.void,
    exec: () => Effect.die("exec unused"),
    openAttach: () => Effect.die("openAttach unused"),
    openSSH: () => Effect.die("openSSH unused"),
    revokeSSHIdentity: () => Effect.void,
  };
}

function layers(
  repo: VmRepositoryShape,
  provider: VmProviderGatewayShape,
  billing: VmBillingGatewayShape = noOpVmBillingGateway(),
) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, billing),
  );
}

function createInput(vm: CloudVmRow) {
  return {
    userId: vm.userId,
    billingCustomerType: "team" as const,
    billingTeamId: vm.billingTeamId ?? vm.userId,
    billingPlanId: "free",
    maxActiveVms: 3,
    provider: vm.provider,
    image: vm.imageId,
  };
}

describe("create-credit reservation ledger", () => {
  test("successful create records the reservation before the debit and commits it", async () => {
    const vm = vmRow();
    const calls: string[] = [];
    const transitions: ReservationTransition[] = [];
    const repo = reservationRepo({ vm, calls, transitions });
    const billing = billingGateway({ calls });

    await Effect.runPromise(
      createVm(createInput(vm)).pipe(Effect.provide(layers(repo, providerGateway(), billing))),
    );

    const insertIndex = calls.indexOf("insertCreditReservation");
    const debitIndex = calls.indexOf("reserveCreate");
    expect(insertIndex).toBeGreaterThanOrEqual(0);
    expect(debitIndex).toBeGreaterThan(insertIndex);
    expect(transitions).toEqual([
      { id: RESERVATION_ID, from: ["pending"], to: "debited" },
      { id: RESERVATION_ID, from: ["pending", "debited"], to: "committed" },
    ]);
  });

  test("provider create failure claims the reservation and refunds exactly once", async () => {
    const vm = vmRow();
    const calls: string[] = [];
    const transitions: ReservationTransition[] = [];
    const refunds: VmCreateCreditReservation[] = [];
    const repo = reservationRepo({ vm, calls, transitions });
    const billing = billingGateway({ calls, refunds });
    const createError = new VmProviderOperationError({
      provider: "freestyle",
      operation: "create",
      cause: new Error("provider exploded"),
    });

    const error = await Effect.runPromise(
      createVm(createInput(vm)).pipe(
        Effect.provide(layers(repo, providerGateway({ createError }), billing)),
        Effect.flip,
      ),
    );

    expect(error._tag).toBe("VmProviderOperationError");
    expect(refunds).toHaveLength(1);
    expect(transitions).toEqual([
      { id: RESERVATION_ID, from: ["pending"], to: "debited" },
      { id: RESERVATION_ID, from: ["pending", "debited"], to: "refunding" },
      { id: RESERVATION_ID, from: ["refunding"], to: "refunded" },
    ]);
  });

  test("refund failure lands the reservation in refund_failed for the reconcile cron", async () => {
    const vm = vmRow();
    const transitions: ReservationTransition[] = [];
    const repo = reservationRepo({ vm, transitions });
    const billing = billingGateway({
      refundError: new VmBillingError({ operation: "refundCreate", cause: new Error("stack down") }),
    });
    const createError = new VmProviderOperationError({
      provider: "freestyle",
      operation: "create",
      cause: new Error("provider exploded"),
    });

    await Effect.runPromise(
      createVm(createInput(vm)).pipe(
        Effect.provide(layers(repo, providerGateway({ createError }), billing)),
        Effect.flip,
      ),
    );

    expect(transitions.at(-1)).toEqual({
      id: RESERVATION_ID,
      from: ["refunding"],
      to: "refund_failed",
    });
  });

  test("a lost refund claim skips the refund instead of risking a double credit", async () => {
    const vm = vmRow();
    const calls: string[] = [];
    const repo = reservationRepo({
      vm,
      calls,
      transitionResult: (transition) => transition.to !== "refunding",
    });
    const billing = billingGateway({ calls });
    const createError = new VmProviderOperationError({
      provider: "freestyle",
      operation: "create",
      cause: new Error("provider exploded"),
    });

    await Effect.runPromise(
      createVm(createInput(vm)).pipe(
        Effect.provide(layers(repo, providerGateway({ createError }), billing)),
        Effect.flip,
      ),
    );

    expect(calls).not.toContain("refundCreate");
  });

  test("insufficient credits releases the pending reservation without a refund", async () => {
    const vm = vmRow();
    const calls: string[] = [];
    const transitions: ReservationTransition[] = [];
    const repo = reservationRepo({ vm, calls, transitions });
    const billing = billingGateway({
      calls,
      reserveError: new VmCreateCreditsInsufficientError({
        itemId: "cmux-vm-create-credit",
        billingCustomerId: "team-credit-reservations",
        amount: 1,
      }),
    });

    const error = await Effect.runPromise(
      createVm(createInput(vm)).pipe(
        Effect.provide(layers(repo, providerGateway(), billing)),
        Effect.flip,
      ),
    );

    expect(error._tag).toBe("VmCreateCreditsInsufficientError");
    expect(transitions).toEqual([{ id: RESERVATION_ID, from: ["pending"], to: "aborted" }]);
    expect(calls).not.toContain("refundCreate");
  });

  test("an uncertain debit failure leaves the reservation pending for the cron", async () => {
    const vm = vmRow();
    const transitions: ReservationTransition[] = [];
    const repo = reservationRepo({ vm, transitions });
    const billing = billingGateway({
      reserveError: new VmBillingError({ operation: "reserveCreate", cause: new Error("timeout") }),
    });

    await Effect.runPromise(
      createVm(createInput(vm)).pipe(
        Effect.provide(layers(repo, providerGateway(), billing)),
        Effect.flip,
      ),
    );

    expect(transitions).toEqual([]);
  });
});

describe("reconcileCreditReservations", () => {
  function reconcile(input: {
    readonly staleReservations: StaleCreditReservation[];
    readonly transitions?: ReservationTransition[];
    readonly usageEvents?: RecordedUsageEvent[];
    readonly billing?: VmBillingGatewayShape;
    readonly transitionResult?: (transition: ReservationTransition) => boolean;
  }) {
    const repo = reservationRepo({
      vm: vmRow(),
      staleReservations: input.staleReservations,
      transitions: input.transitions,
      usageEvents: input.usageEvents,
      transitionResult: input.transitionResult,
    });
    return Effect.runPromise(
      reconcileCreditReservations().pipe(
        Effect.provide(layers(repo, providerGateway(), input.billing ?? billingGateway({}))),
      ),
    );
  }

  test("refunds a debited reservation whose create failed", async () => {
    const transitions: ReservationTransition[] = [];
    const usageEvents: RecordedUsageEvent[] = [];
    const refunds: VmCreateCreditReservation[] = [];
    const result = await reconcile({
      staleReservations: [
        { reservation: reservationRow({ status: "debited" }), vm: vmRow({ status: "failed" }) },
      ],
      transitions,
      usageEvents,
      billing: billingGateway({ refunds }),
    });

    expect(result).toMatchObject({ checked: 1, refunded: 1, supported: true });
    expect(refunds).toEqual([stackReservation()]);
    expect(transitions).toEqual([
      { id: RESERVATION_ID, from: ["debited"], to: "refunding" },
      { id: RESERVATION_ID, from: ["refunding"], to: "refunded" },
    ]);
    expect(usageEvents.map((event) => event.eventType)).toContain("vm.create.credit.refunded");
  });

  test("retries refund_failed reservations and keeps them on refund failure", async () => {
    const transitions: ReservationTransition[] = [];
    const result = await reconcile({
      staleReservations: [
        { reservation: reservationRow({ status: "refund_failed" }), vm: vmRow({ status: "failed" }) },
      ],
      transitions,
      billing: billingGateway({
        refundError: new VmBillingError({ operation: "refundCreate", cause: new Error("still down") }),
      }),
    });

    expect(result).toMatchObject({ refundFailed: 1 });
    expect(transitions).toEqual([
      { id: RESERVATION_ID, from: ["refund_failed"], to: "refunding" },
      { id: RESERVATION_ID, from: ["refunding"], to: "refund_failed" },
    ]);
  });

  test("commits a debited reservation whose VM is running (lost commit write)", async () => {
    const transitions: ReservationTransition[] = [];
    const refunds: VmCreateCreditReservation[] = [];
    const result = await reconcile({
      staleReservations: [
        {
          reservation: reservationRow({ status: "debited" }),
          vm: vmRow({ status: "running", providerVmId: "provider-vm-1" }),
        },
      ],
      transitions,
      billing: billingGateway({ refunds }),
    });

    expect(result).toMatchObject({ committed: 1, refunded: 0 });
    expect(refunds).toHaveLength(0);
    expect(transitions).toEqual([
      { id: RESERVATION_ID, from: ["pending", "debited"], to: "committed" },
    ]);
  });

  test("never refunds a pending reservation (debit outcome unknowable)", async () => {
    const transitions: ReservationTransition[] = [];
    const refunds: VmCreateCreditReservation[] = [];
    const result = await reconcile({
      staleReservations: [
        { reservation: reservationRow({ status: "pending" }), vm: vmRow({ status: "failed" }) },
      ],
      transitions,
      billing: billingGateway({ refunds }),
    });

    expect(result).toMatchObject({ abandoned: 1, refunded: 0 });
    expect(refunds).toHaveLength(0);
    expect(transitions).toEqual([{ id: RESERVATION_ID, from: ["pending"], to: "abandoned" }]);
  });

  test("skips reservations whose VM is still provisioning", async () => {
    const refunds: VmCreateCreditReservation[] = [];
    const result = await reconcile({
      staleReservations: [
        { reservation: reservationRow({ status: "debited" }), vm: vmRow({ status: "provisioning" }) },
      ],
      billing: billingGateway({ refunds }),
    });

    expect(result).toMatchObject({ skipped: 1, refunded: 0 });
    expect(refunds).toHaveLength(0);
  });

  test("reports unsupported repositories without failing", async () => {
    const repo = { ...reservationRepo({ vm: vmRow() }) };
    delete (repo as Record<string, unknown>).staleCreditReservations;
    const result = await Effect.runPromise(
      reconcileCreditReservations().pipe(
        Effect.provide(layers(repo, providerGateway(), billingGateway({}))),
      ),
    );
    expect(result.supported).toBe(false);
  });
});

describe("sweepStuckProvisioningVms", () => {
  test("fails stuck rows and records a usage event per swept row", async () => {
    const usageEvents: RecordedUsageEvent[] = [];
    const sweptRows = [
      vmRow({ id: "00000000-0000-4000-8000-000000000011", status: "failed" }),
      vmRow({ id: "00000000-0000-4000-8000-000000000012", status: "failed" }),
    ];
    const sweepInputs: { olderThan: Date; limit: number }[] = [];
    const repo = reservationRepo({
      vm: vmRow(),
      usageEvents,
      sweepStuckProvisioning: (input) =>
        Effect.sync(() => {
          sweepInputs.push(input);
          return sweptRows;
        }),
    });

    const result = await Effect.runPromise(
      sweepStuckProvisioningVms({ now: new Date("2026-01-01T01:00:00.000Z") }).pipe(
        Effect.provide(layers(repo, providerGateway())),
      ),
    );

    expect(result).toEqual({ swept: 2, supported: true });
    expect(sweepInputs[0]?.olderThan).toEqual(new Date("2026-01-01T00:30:00.000Z"));
    expect(usageEvents).toHaveLength(2);
    expect(usageEvents.every((event) => event.eventType === "vm.create.failed")).toBe(true);
    expect(usageEvents[0]?.metadata).toMatchObject({ source: "stuck_provisioning_sweeper" });
  });

  test("reports unsupported repositories without failing", async () => {
    const repo = reservationRepo({ vm: vmRow() });
    const result = await Effect.runPromise(
      sweepStuckProvisioningVms().pipe(Effect.provide(layers(repo, providerGateway()))),
    );
    expect(result).toEqual({ swept: 0, supported: false });
  });
});
