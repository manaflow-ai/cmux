// Devbox product: exactly one persistent Daytona VM per user with a per-user
// persistent volume. The VM is a normal `cloud_vms` row so leases, usage events,
// reconcile, billing, and account deletion all keep working; `cloud_devboxes` adds
// the single-active claim (partial unique index on user_id) and the volume binding.
//
// Lifecycle:
// - ensure: get-or-create. Volume is get-or-create by stable per-user name, so a
//   recreated devbox mounts the same data. Concurrent first-creates are resolved by
//   the unique index; the loser destroys its VM and adopts the winner's claim.
// - pause/resume: explicit workflows over Daytona stop/start. Stop preserves the
//   sandbox filesystem; resume restarts cmuxd-remote and is limit-gated in Postgres.
// - release: destroys the VM and releases the claim. The volume is deliberately
//   retained; the next ensure reattaches it.

import { createHash } from "node:crypto";
import { and, eq, isNull } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import { cloudDevboxes, cloudVms } from "../../db/schema";
import type { BillingCustomerType } from "./billingGateway";
import { ensureDaytonaVolume } from "./drivers/daytona";
import {
  VmDatabaseError,
  VmNotFoundError,
  VmProviderOperationError,
  vmWorkflowErrorCause,
  type VmWorkflowError,
} from "./errors";
import { VmBillingGateway } from "./billingGateway";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository, type CloudVmRow } from "./repository";
import {
  createVm,
  destroyVm,
  getVm,
  openAttachEndpoint,
  pauseVm,
  resumeVm,
  VmWorkflowLive,
} from "./workflows";
import type { AttachOptions } from "./drivers";

export const DEVBOX_PERSIST_MOUNT_PATH = "/home/cmux/persist";
export const DEVBOX_PROVIDER = "daytona" as const;

export type CloudDevboxRow = typeof cloudDevboxes.$inferSelect;

export type DevboxEntry = {
  readonly id: string;
  readonly status: CloudVmRow["status"];
  readonly provider: typeof DEVBOX_PROVIDER;
  readonly providerVmId: string | null;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly volume: {
    readonly id: string;
    readonly name: string;
    readonly mountPath: string;
  };
  readonly createdAt: number;
};

type ActiveDevbox = {
  readonly devbox: CloudDevboxRow;
  readonly vm: CloudVmRow;
};

export type DevboxRepositoryShape = {
  readonly findActive: (userId: string) => Effect.Effect<ActiveDevbox | null, VmDatabaseError>;
  readonly claim: (input: {
    readonly userId: string;
    readonly vmId: string;
    readonly volumeId: string;
    readonly volumeName: string;
  }) => Effect.Effect<{ readonly inserted: boolean; readonly devbox: CloudDevboxRow }, VmDatabaseError>;
  readonly release: (userId: string) => Effect.Effect<CloudDevboxRow | null, VmDatabaseError>;
};

export class DevboxRepository extends Context.Tag("cmux/DevboxRepository")<
  DevboxRepository,
  DevboxRepositoryShape
>() {}

async function selectActive(userId: string) {
  const db = cloudDb();
  const [row] = await db
    .select({ devbox: cloudDevboxes, vm: cloudVms })
    .from(cloudDevboxes)
    .innerJoin(cloudVms, eq(cloudDevboxes.vmId, cloudVms.id))
    .where(and(eq(cloudDevboxes.userId, userId), isNull(cloudDevboxes.releasedAt)))
    .limit(1);
  return row ?? null;
}

async function releaseClaim(userId: string): Promise<CloudDevboxRow | null> {
  const db = cloudDb();
  const [released] = await db
    .update(cloudDevboxes)
    .set({ releasedAt: new Date(), updatedAt: new Date() })
    .where(and(eq(cloudDevboxes.userId, userId), isNull(cloudDevboxes.releasedAt)))
    .returning();
  return released ?? null;
}

export const DevboxRepositoryLive = Layer.succeed(DevboxRepository, {
  findActive: (userId) =>
    Effect.tryPromise({
      try: async () => {
        const row = await selectActive(userId);
        if (!row) return null;
        // Heal drift: the VM can be destroyed through /api/vm/[id] without going
        // through releaseDevbox. A claim on a destroyed VM would block ensure
        // forever, so release it here and report no devbox.
        if (row.vm.status === "destroyed") {
          await releaseClaim(userId);
          return null;
        }
        return row;
      },
      catch: (cause) => new VmDatabaseError({ operation: "devboxFindActive", cause }),
    }),
  claim: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        try {
          const [devbox] = await db
            .insert(cloudDevboxes)
            .values({
              userId: input.userId,
              vmId: input.vmId,
              volumeId: input.volumeId,
              volumeName: input.volumeName,
            })
            .returning();
          if (!devbox) throw new Error("insert returned no devbox row");
          return { inserted: true as const, devbox };
        } catch (err) {
          // 23505 on the partial unique index means a concurrent ensure won the
          // single-active slot; surface the winner so the caller can adopt it.
          if (pgErrorCode(err) === "23505") {
            const existing = await selectActive(input.userId);
            if (existing) return { inserted: false as const, devbox: existing.devbox };
          }
          throw err;
        }
      },
      catch: (cause) => new VmDatabaseError({ operation: "devboxClaim", cause }),
    }),
  release: (userId) =>
    Effect.tryPromise({
      try: () => releaseClaim(userId),
      catch: (cause) => new VmDatabaseError({ operation: "devboxRelease", cause }),
    }),
});

export const DevboxWorkflowLive = Layer.mergeAll(VmWorkflowLive, DevboxRepositoryLive);

type DevboxWorkflowContext =
  | VmRepository
  | VmProviderGateway
  | VmBillingGateway
  | DevboxRepository;

export async function runDevboxWorkflow<A>(
  program: Effect.Effect<A, VmWorkflowError, DevboxWorkflowContext>,
): Promise<A> {
  try {
    return await Effect.runPromise(program.pipe(Effect.provide(DevboxWorkflowLive)));
  } catch (err) {
    throw vmWorkflowErrorCause(err) ?? err;
  }
}

/**
 * Stable per-user volume name. Hashed so no user identifier lands in provider-side
 * resource names; stable so destroy + recreate reattaches the same data.
 */
export function devboxVolumeName(userId: string): string {
  const digest = createHash("sha256").update(userId).digest("hex").slice(0, 24);
  return `cmux-devbox-${digest}`;
}

function devboxEntry(active: ActiveDevbox): DevboxEntry {
  return {
    id: active.devbox.id,
    status: active.vm.status,
    provider: DEVBOX_PROVIDER,
    providerVmId: active.vm.providerVmId,
    image: active.vm.imageId,
    imageVersion: active.vm.imageVersion,
    volume: {
      id: active.devbox.volumeId,
      name: active.devbox.volumeName,
      mountPath: DEVBOX_PERSIST_MOUNT_PATH,
    },
    createdAt: active.devbox.createdAt.getTime(),
  };
}

const devboxNotFound = () => new VmNotFoundError({ vmId: "devbox" });

type DevboxScope = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
};

function requireActiveDevbox(userId: string) {
  return Effect.gen(function* () {
    const devboxes = yield* DevboxRepository;
    const active = yield* devboxes.findActive(userId);
    if (!active) return yield* Effect.fail(devboxNotFound());
    return active;
  });
}

function requireAttachedDevbox(userId: string) {
  return Effect.gen(function* () {
    const active = yield* requireActiveDevbox(userId);
    const providerVmId = active.vm.providerVmId;
    if (!providerVmId) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: DEVBOX_PROVIDER,
          operation: "requireAttachedDevbox",
          cause: new Error("devbox VM is still provisioning"),
        }),
      );
    }
    return { active, providerVmId };
  });
}

export function ensureDevbox(input: DevboxScope & {
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly idempotencyKey?: string;
}): Effect.Effect<
  { readonly devbox: DevboxEntry; readonly created: boolean },
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const devboxes = yield* DevboxRepository;
    const repo = yield* VmRepository;

    const existing = yield* devboxes.findActive(input.userId);
    if (existing) return { devbox: devboxEntry(existing), created: false };

    const volumeName = devboxVolumeName(input.userId);
    const volume = yield* Effect.tryPromise({
      try: () => ensureDaytonaVolume(volumeName),
      catch: (cause) =>
        new VmProviderOperationError({
          provider: DEVBOX_PROVIDER,
          operation: `ensureVolume(${volumeName})`,
          cause,
        }),
    });

    const vmEntry = yield* createVm({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      maxActiveVms: input.maxActiveVms,
      provider: DEVBOX_PROVIDER,
      image: input.image,
      imageVersion: input.imageVersion,
      idempotencyKey: input.idempotencyKey,
      volumes: [{ volumeId: volume.id, mountPath: DEVBOX_PERSIST_MOUNT_PATH }],
      envVars: {
        CMUX_DEVBOX: "1",
        CMUX_DEVBOX_PERSIST: DEVBOX_PERSIST_MOUNT_PATH,
      },
    });

    const vmRow = yield* repo.findUserVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      providerVmId: vmEntry.providerVmId,
      provider: DEVBOX_PROVIDER,
    });
    if (!vmRow) return yield* Effect.fail(new VmNotFoundError({ vmId: vmEntry.providerVmId }));

    const claim = yield* devboxes.claim({
      userId: input.userId,
      vmId: vmRow.id,
      volumeId: volume.id,
      volumeName: volume.name,
    });

    if (!claim.inserted && claim.devbox.vmId !== vmRow.id) {
      // A concurrent ensure claimed the slot with a different VM. The invariant
      // is one VM per user, so destroy the VM this call just created and adopt
      // the winner's devbox.
      yield* destroyVm({
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        teamIds: input.teamIds,
        providerVmId: vmEntry.providerVmId,
        provider: DEVBOX_PROVIDER,
      }).pipe(Effect.catchAll(() => Effect.void));
      const winner = yield* devboxes.findActive(input.userId);
      if (!winner) return yield* Effect.fail(devboxNotFound());
      return { devbox: devboxEntry(winner), created: false };
    }

    return {
      devbox: devboxEntry({ devbox: claim.devbox, vm: vmRow }),
      created: claim.inserted,
    };
  });
}

export function getDevbox(input: DevboxScope): Effect.Effect<
  DevboxEntry | null,
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const devboxes = yield* DevboxRepository;
    const active = yield* devboxes.findActive(input.userId);
    if (!active) return null;
    if (!active.vm.providerVmId) return devboxEntry(active);
    // getVm reconciles provider-observed status into the row, so pause/resume
    // performed out of band is reflected in the durable answer.
    const vm = yield* getVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId: active.vm.providerVmId,
    });
    return devboxEntry({ devbox: active.devbox, vm: { ...active.vm, status: vm.status } });
  });
}

export function pauseDevbox(input: DevboxScope): Effect.Effect<
  DevboxEntry,
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const { active, providerVmId } = yield* requireAttachedDevbox(input.userId);
    const vm = yield* pauseVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId,
      provider: DEVBOX_PROVIDER,
    });
    return devboxEntry({ devbox: active.devbox, vm: { ...active.vm, status: vm.status } });
  });
}

export function resumeDevbox(input: DevboxScope): Effect.Effect<
  DevboxEntry,
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const { active, providerVmId } = yield* requireAttachedDevbox(input.userId);
    const vm = yield* resumeVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId,
      provider: DEVBOX_PROVIDER,
    });
    return devboxEntry({ devbox: active.devbox, vm: { ...active.vm, status: vm.status } });
  });
}

export function releaseDevbox(input: DevboxScope): Effect.Effect<
  { readonly released: boolean; readonly volumeName: string },
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const devboxes = yield* DevboxRepository;
    const active = yield* requireActiveDevbox(input.userId);
    if (active.vm.providerVmId && active.vm.status !== "destroyed") {
      yield* destroyVm({
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        teamIds: input.teamIds,
        providerVmId: active.vm.providerVmId,
        provider: DEVBOX_PROVIDER,
      }).pipe(
        // Already gone on the provider or another destroy raced us: releasing
        // the claim is still correct.
        Effect.catchTag("VmNotFoundError", () => Effect.void),
      );
    }
    yield* devboxes.release(input.userId);
    // The volume is retained on purpose: it is the persistence story. The next
    // ensure for this user reattaches it by stable name.
    return { released: true, volumeName: active.devbox.volumeName };
  });
}

export function openDevboxAttach(input: DevboxScope & {
  readonly sessionTitle?: string | null;
  readonly options?: AttachOptions;
}): Effect.Effect<
  Effect.Effect.Success<ReturnType<typeof openAttachEndpoint>>,
  VmWorkflowError,
  DevboxWorkflowContext
> {
  return Effect.gen(function* () {
    const { providerVmId } = yield* requireAttachedDevbox(input.userId);
    // openAttachEndpoint auto-resumes a paused VM before minting the lease, so
    // attaching to a paused devbox transparently resumes it.
    return yield* openAttachEndpoint({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId,
      sessionTitle: input.sessionTitle,
      options: input.options,
    });
  });
}

export function isDevboxNotFoundError(err: unknown): boolean {
  return (err as { _tag?: string; vmId?: string } | null)?._tag === "VmNotFoundError"
    && (err as { vmId?: string }).vmId === "devbox";
}

function pgErrorCode(cause: unknown): string | null {
  if (typeof cause !== "object" || cause === null) return null;
  const code = (cause as { code?: unknown }).code;
  return typeof code === "string" ? code : null;
}
