import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";

import {
  addressReleaseFromMetadata,
  addressReleaseIneligibleReason,
  pausedAddressReleaseHours,
  VM_ADDRESS_RELEASE_SNAPSHOT_NAME,
  type VmAddressRelease,
  type VmAddressReleaseState,
} from "../services/vms/addressRelease";
import { releasePausedAddresses } from "../services/vms/addressReleaseJob";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import type { VmPauseState } from "../services/vms/drivers/types";
import { VmCreateWaitingError, VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import { resetFleetAdmissionForTest } from "../services/vms/fleetAdmission";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, parkedRestoreIdempotencyKey, reconcileVmProviderStatuses, requireUserVm, resumeParkedVm, resumeVm } from "../services/vms/workflows";
import type { VmCreateWait } from "../services/vms/createWait";

// Leo, 2026-11-28: "Paused sandboxes must release addresses or have bounded expiry."
const USER_ID = "user-park";
const TEAM_ID = "team-park";
const ON = { CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS: "24" };
const NOW = Date.parse("2026-11-28T12:00:00Z");
const LONG_AGO = new Date(NOW - 48 * 3_600_000);

// A /29 holds 6 addresses, so six paused machines fill it.
const network = {
  id: "00000000-0000-4000-8000-0000000000aa",
  userId: USER_ID,
  provider: "freestyle" as const,
  providerNetworkId: "vpc-park",
  slug: "cmux-net-park",
  cidr: "10.40.0.0/29",
  cidrV6: "fd40::/64",
  createdAt: new Date(),
  updatedAt: new Date(),
};

/** A recorded machine shape the free plan can restore (it allows 8 GB). */
const SHAPE = { vcpus: 2, memoryMb: 4096, diskMb: 16384 };

let seq = 0;
function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  seq += 1;
  return {
    id: `00000000-0000-4000-8000-${String(seq).padStart(12, "0")}`,
    userId: USER_ID,
    ownerTeamId: TEAM_ID,
    coderouterPoolId: null,
    billingTeamId: TEAM_ID,
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: `machine-${seq}`,
    displayName: null,
    slug: null,
    imageId: "image",
    imageVersion: null,
    status: "paused",
    idempotencyKey: null,
    createdAt: LONG_AGO,
    updatedAt: LONG_AGO,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: { networkIpv4: `10.40.0.${seq % 6 + 1}`, cmuxResourceReservation: SHAPE },
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ...overrides,
  } as CloudVmRow;
}

type Fleet = {
  readonly rows: CloudVmRow[];
  readonly snapshotsTaken: string[];
  readonly destroyed: string[];
  readonly creates: string[];
  readonly ownedSnapshots: Set<string>;
  readonly repo: VmRepositoryShape;
  readonly gateway: VmProviderGatewayShape;
  /** Provider pause state per machine; default "paused". */
  readonly pauseState: Map<string, VmPauseState>;
  /** Successive pause-state reads for one machine, consumed before `pauseState`. */
  readonly pauseStateQueue: Map<string, VmPauseState[]>;
  fail: { snapshot?: boolean; listMissing?: boolean; destroy?: boolean; fenceLost?: boolean };
};

function fleet(rows: CloudVmRow[]): Fleet {
  const snapshotsTaken: string[] = [];
  const destroyed: string[] = [];
  const creates: string[] = [];
  const ownedSnapshots = new Set<string>();
  const snapshotShapes = new Map<string, { vcpus: number; memoryMb: number; diskMb: number }>();
  const pauseState = new Map<string, VmPauseState>();
  const pauseStateQueue = new Map<string, VmPauseState[]>();
  const f: Fleet = {
    rows, snapshotsTaken, destroyed, creates, ownedSnapshots, pauseState, pauseStateQueue,
    fail: {},
    repo: undefined as never,
    gateway: undefined as never,
  };
  const releaseOf = (r: CloudVmRow) => addressReleaseFromMetadata(r.providerMetadata);
  const replace = (next: CloudVmRow) => {
    const index = rows.findIndex((r) => r.id === next.id);
    rows[index] = next;
    return next;
  };
  const repo = {
    // --- park job ---
    addressReleaseCandidates: (input: { pausedBefore: Date; limit: number }) => Effect.sync(() => rows.filter((r) =>
      r.status === "paused" && r.provider === "freestyle" && !!r.providerVmId
      && ((!releaseOf(r) && r.updatedAt < input.pausedBefore) || releaseOf(r)?.state === "parking")).slice(0, input.limit)),
    writeAddressRelease: (input: {
      id: string; providerVmId: string; fromStatus: "paused"; fromState: VmAddressReleaseState | null;
      updatedAt?: Date; release: VmAddressRelease; releaseAddress?: boolean; toStatus?: "destroyed";
    }) => Effect.sync(() => {
      const current = rows.find((r) => r.id === input.id);
      if (!current || f.fail.fenceLost) return false;
      if (current.providerVmId !== input.providerVmId || current.status !== input.fromStatus) return false;
      if ((releaseOf(current)?.state ?? null) !== input.fromState) return false;
      if (input.updatedAt && current.updatedAt.getTime() !== input.updatedAt.getTime()) return false;
      const metadata: Record<string, unknown> = { ...current.providerMetadata, addressRelease: input.release };
      if (input.releaseAddress) delete metadata.networkIpv4;
      replace({
        ...current,
        providerMetadata: metadata,
        updatedAt: new Date(current.updatedAt.getTime() + 1),
        ...(input.toStatus === "destroyed" ? { status: "destroyed" as const, destroyedAt: new Date() } : {}),
      });
      return true;
    }),
    findAddressReleaseSuccessor: (input: { providerVmId: string }) => Effect.sync(() => {
      const parked = rows.find((r) => r.providerVmId === input.providerVmId && r.status === "destroyed" && releaseOf(r)?.state === "restored");
      return parked ? releaseOf(parked)?.successorProviderVmId ?? null : null;
    }),
    hasOwnedSnapshot: (input: { snapshotId: string }) => Effect.sync(() => ownedSnapshots.has(input.snapshotId)),
    recordSnapshotUsageEventIfMissing: (event: { metadata: { snapshotId: string; vcpus: number; memoryMb: number; diskMb: number } }) => Effect.sync(() => {
      ownedSnapshots.add(event.metadata.snapshotId);
      snapshotShapes.set(event.metadata.snapshotId, { vcpus: event.metadata.vcpus, memoryMb: event.metadata.memoryMb, diskMb: event.metadata.diskMb });
    }),
    ownedSnapshotResourceReservation: (input: { snapshotId: string }) => Effect.sync(() => snapshotShapes.get(input.snapshotId) ?? null),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    // --- lookups ---
    findUserVm: (input: { providerVmId: string }) => Effect.sync(() =>
      rows.find((r) => r.providerVmId === input.providerVmId && r.status !== "destroyed") ?? null),
    // --- create path (createWait / networkAdmission) ---
    countNetworkAddressHolders: () => Effect.sync(() => rows.filter((r) =>
      r.status !== "destroyed" && r.status !== "failed"
      && (typeof r.providerMetadata?.networkIpv4 === "string" || r.status === "provisioning")).length),
    findCreateByIdempotencyKey: (input: { idempotencyKey: string }) => Effect.sync(() =>
      rows.find((r) => r.idempotencyKey === input.idempotencyKey) ?? null),
    beginCreate: (input: { idempotencyKey?: string; userId: string; billingTeamId: string }) => Effect.sync(() => {
      const existing = rows.find((r) => !!input.idempotencyKey && r.idempotencyKey === input.idempotencyKey);
      if (existing) return { inserted: true, vm: replace({ ...existing, status: "provisioning", providerMetadata: { ...existing.providerMetadata } }) };
      const vm = row({ status: "provisioning", providerVmId: null, idempotencyKey: input.idempotencyKey ?? null, providerMetadata: {}, updatedAt: new Date(), createdAt: new Date() });
      rows.push(vm);
      return { inserted: true, vm };
    }),
    recordCreateWait: (input: { id: string; wait: VmCreateWait }) => Effect.sync(() => {
      const current = rows.find((r) => r.id === input.id)!;
      replace({ ...current, status: "failed", failureCode: "provider_create_unavailable", providerMetadata: { ...current.providerMetadata, createWait: input.wait } });
      return true;
    }),
    markCreateRunning: (input: { id: string; providerVmId: string }) => Effect.sync(() => {
      const current = rows.find((r) => r.id === input.id)!;
      return replace({ ...current, status: "running", providerVmId: input.providerVmId, providerMetadata: { ...current.providerMetadata, networkIpv4: "10.40.0.6" } });
    }),
    markCreateFailed: () => Effect.succeed(true),
    findNetwork: () => Effect.succeed(network),
    upsertNetwork: () => Effect.succeed(network),
    // --- reconcile ---
    reconciliationCandidates: () => Effect.sync(() => rows.filter((r) => r.status === "paused")),
    markProviderObservedStatus: () => Effect.die(new Error("a parked row must not be rewritten from a provider read")),
    markDestroyed: () => Effect.die(new Error("a parked row must not be retired by a provider read")),
  } as unknown as VmRepositoryShape;
  let snapshotSeq = 0;
  const listed = new Map<string, string[]>();
  const gateway = {
    snapshot: (_provider: string, vmId: string, name?: string) => Effect.suspend(() => {
      if (f.fail.snapshot) return Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "snapshot", cause: new Error("snapshot refused") }));
      snapshotSeq += 1;
      const id = `snap-${vmId}-${snapshotSeq}`;
      snapshotsTaken.push(id);
      if (!f.fail.listMissing) listed.set(vmId, [...(listed.get(vmId) ?? []), id]);
      expect(name).toBe(VM_ADDRESS_RELEASE_SNAPSHOT_NAME);
      return Effect.succeed({ id, createdAt: NOW, name });
    }),
    listSnapshots: (_provider: string, vmId: string) => Effect.sync(() => (listed.get(vmId) ?? []).map((id) => ({ id, createdAt: NOW }))),
    getPauseState: (_provider: string, vmId: string) => Effect.sync(() => {
      const queued = pauseStateQueue.get(vmId);
      if (queued?.length) return queued.shift()!;
      return destroyed.includes(vmId) ? "destroyed" : pauseState.get(vmId) ?? "paused";
    }),
    getStatus: () => Effect.succeed("destroyed"),
    resume: () => Effect.die(new Error("a parked row must not be resumed in place")),
    destroy: (_provider: string, vmId: string) => Effect.suspend(() => {
      if (f.fail.destroy) return Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "destroy", cause: new Error("destroy timed out") }));
      destroyed.push(vmId);
      return Effect.void;
    }),
    create: (_provider: string, opts: { image: string }) => Effect.sync(() => {
      creates.push(opts.image);
      return { provider: "freestyle", providerVmId: `restored-${creates.length}`, status: "running", image: opts.image, createdAt: Date.now() };
    }),
    supportsPrivateNetworking: () => true,
    getNetwork: () => Effect.succeed(null),
    ensureNetwork: () => Effect.succeed({ id: network.providerNetworkId, slug: network.slug, cidr: network.cidr, cidrV6: network.cidrV6 }),
    listNetworkTunnelIds: () => Effect.succeed([]),
  } as unknown as VmProviderGatewayShape;
  Object.assign(f, { repo, gateway });
  return f;
}

function layer(f: Fleet) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, f.repo),
    Layer.succeed(VmProviderGateway, f.gateway),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

function park(f: Fleet, env: Record<string, string> = ON) {
  return Effect.runPromise(releasePausedAddresses({ now: () => NOW, env }).pipe(Effect.provide(layer(f))));
}

function failure(exit: Exit.Exit<unknown, unknown>): unknown {
  if (Exit.isSuccess(exit)) throw new Error("expected a failure");
  return (exit.cause as { error?: unknown }).error ?? exit.cause;
}

const release = (r: CloudVmRow | undefined) => addressReleaseFromMetadata(r?.providerMetadata);

beforeEach(() => {
  resetFleetAdmissionForTest();
  seq = 0;
});

describe("paused address release: off by default", () => {
  test("the env var must be a positive number", () => {
    expect(pausedAddressReleaseHours({})).toBeNull();
    expect(pausedAddressReleaseHours({ CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS: "0" })).toBeNull();
    expect(pausedAddressReleaseHours({ CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS: "nope" })).toBeNull();
    expect(pausedAddressReleaseHours({ CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS: "12" })).toBe(12);
  });

  test("with the flag unset nothing is snapshotted or destroyed", async () => {
    const f = fleet([row()]);
    const summary = await park(f, {});
    expect(summary).toMatchObject({ enabled: false, parked: 0 });
    expect(f.snapshotsTaken).toHaveLength(0);
    expect(f.destroyed).toHaveLength(0);
  });
});

describe("paused address release: a failed or unverified snapshot destroys nothing", () => {
  test("a snapshot the provider refuses leaves the machine and its address", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.fail.snapshot = true;
    const summary = await park(f);
    expect(summary).toMatchObject({ enabled: true, checked: 1, parked: 0, errors: 1 });
    expect(f.destroyed).toHaveLength(0);
    expect(f.rows[0]).toEqual(vm);
  });

  test("a snapshot missing from the provider's list leaves the machine and its address", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.fail.listMissing = true;
    const summary = await park(f);
    expect(summary).toMatchObject({ parked: 0, errors: 1 });
    expect(f.snapshotsTaken).toHaveLength(1);
    expect(f.destroyed).toHaveLength(0);
    expect(f.rows[0]).toEqual(vm);
    expect(f.ownedSnapshots.size).toBe(0);
  });

  test("a row changed since it was read (resume, attach) is not destroyed", async () => {
    const f = fleet([row()]);
    f.fail.fenceLost = true;
    const summary = await park(f);
    expect(summary).toMatchObject({ parked: 0, skipped: 1 });
    expect(f.destroyed).toHaveLength(0);
    expect(release(f.rows[0])).toBeNull();
  });

  test("a machine that woke after the snapshot is not destroyed", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.pauseStateQueue.set(vm.providerVmId!, ["paused", "not_paused"]);
    const summary = await park(f);
    expect(summary).toMatchObject({ parked: 0, skipped: 1 });
    expect(f.destroyed).toHaveLength(0);
    expect(release(f.rows[0])?.state).toBe("parking");
    expect(f.rows[0]?.providerMetadata?.networkIpv4).toBe(vm.providerMetadata?.networkIpv4);
  });

  test("a machine the provider does not report paused is not snapshotted", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.pauseState.set(vm.providerVmId!, "not_paused");
    expect(await park(f)).toMatchObject({ parked: 0, skipped: 1 });
    expect(f.snapshotsTaken).toHaveLength(0);
  });

  test("a destroy failure keeps the address counted and the next run finishes", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.fail.destroy = true;
    expect(await park(f)).toMatchObject({ parked: 0, errors: 1 });
    expect(release(f.rows[0])?.state).toBe("parking");
    expect(f.rows[0]?.providerMetadata?.networkIpv4).toBe(vm.providerMetadata?.networkIpv4);
    f.fail.destroy = false;
    expect(await park(f)).toMatchObject({ parked: 1 });
    const parked = release(f.rows[0])!;
    expect(parked.state).toBe("parked");
    expect(f.ownedSnapshots.has(parked.snapshotId)).toBe(true);
    expect(f.rows[0]?.providerMetadata?.networkIpv4).toBeUndefined();
  });

  test("a run that destroyed the machine but did not record it finishes from the recorded snapshot", async () => {
    const vm = row();
    const f = fleet([vm]);
    f.pauseStateQueue.set(vm.providerVmId!, ["paused", "paused"]);
    // Simulate the crash: the parking write lands, the destroy lands, the final write is lost once.
    const write = f.repo.writeAddressRelease!;
    let lose = true;
    (f.repo as { writeAddressRelease: typeof write }).writeAddressRelease = (input) =>
      input.fromState === "parking" && lose ? Effect.sync(() => { lose = false; return false; }) : write(input);
    await park(f);
    expect(f.destroyed).toEqual([vm.providerVmId!]);
    expect(release(f.rows[0])?.state).toBe("parking");
    expect(await park(f)).toMatchObject({ parked: 1 });
    expect(f.snapshotsTaken).toHaveLength(1);
    expect(release(f.rows[0])?.state).toBe("parked");
  });
});

describe("paused address release: eligibility", () => {
  test("only plain paused machines with an address park", () => {
    expect(addressReleaseIneligibleReason(row(), false)).toBeNull();
    expect(addressReleaseIneligibleReason(row({ provider: "e2b" as never }), false)).toBe("provider");
    expect(addressReleaseIneligibleReason(row({ status: "running" }), false)).toBe("status");
    expect(addressReleaseIneligibleReason(row({ providerVmId: null }), false)).toBe("no_provider_vm");
    expect(addressReleaseIneligibleReason(row(), true)).toBe("sandbox_run");
    expect(addressReleaseIneligibleReason(row({ providerMetadata: { networkIpv4: "10.40.0.2", homeVolume: "home-x" } }), false)).toBe("home_volume");
    expect(addressReleaseIneligibleReason(row({ providerMetadata: {} }), false)).toBe("no_address");
  });

  test("a machine with a home volume is never snapshotted or destroyed", async () => {
    const f = fleet([row({ providerMetadata: { networkIpv4: "10.40.0.2", homeVolume: "home-x" } })]);
    expect(await park(f)).toMatchObject({ checked: 1, parked: 0, skipped: 1 });
    expect(f.snapshotsTaken).toHaveLength(0);
    expect(f.destroyed).toHaveLength(0);
  });

  test("a machine its plan could not restore is never snapshotted or destroyed", async () => {
    // No recorded shape claims the provider maximum, which the free plan refuses on restore.
    const unshaped = row({ providerMetadata: { networkIpv4: "10.40.0.2" } });
    const tooBig = row({ providerMetadata: { networkIpv4: "10.40.0.3", cmuxResourceReservation: { vcpus: 8, memoryMb: 32768, diskMb: 16384 } } });
    const f = fleet([unshaped, tooBig]);
    expect(await park(f)).toMatchObject({ checked: 2, parked: 0, skipped: 2 });
    expect(f.snapshotsTaken).toHaveLength(0);
    expect(f.destroyed).toHaveLength(0);
  });
});

describe("paused address release: other paths leave parked rows alone", () => {
  test("reconcile does not retire a parked row whose provider machine is gone", async () => {
    const f = fleet([row()]);
    await park(f);
    expect(release(f.rows[0])?.state).toBe("parked");
    const result = await Effect.runPromise(reconcileVmProviderStatuses().pipe(Effect.provide(layer(f))));
    expect(result).toMatchObject({ checked: 1, skipped: 1, destroyed: 0 });
    expect(f.rows[0]?.status).toBe("paused");
  });

  test("a plain resume of a parked row refuses instead of probing the provider", async () => {
    const vm = row();
    const f = fleet([vm]);
    await park(f);
    const exit = await Effect.runPromiseExit(resumeVm({ userId: USER_ID, billingTeamId: TEAM_ID, teamIds: [TEAM_ID], providerVmId: vm.providerVmId! }).pipe(Effect.provide(layer(f))));
    expect(failure(exit)).toBeInstanceOf(VmOperationUnsupportedError);
    expect(f.rows[0]?.status).toBe("paused");
    expect(release(f.rows[0])?.state).toBe("parked");
  });
});

describe("paused address release: a start at the cap waits, then starts once a parked row frees its address", () => {
  const createInput = {
    userId: USER_ID,
    billingCustomerType: "user" as const,
    billingTeamId: TEAM_ID,
    billingPlanId: "free",
    maxActiveVms: null,
    provider: "freestyle" as const,
    image: "image",
    idempotencyKey: "start-at-cap",
    waitForCapacity: true,
  };

  test("create: waiting_for_address, park, then the same-key retry starts", async () => {
    // Six paused machines fill the /29; only the oldest has been paused past the bound.
    const fresh = new Date(NOW - 3_600_000);
    const rows = [row(), ...Array.from({ length: 5 }, () => row({ updatedAt: fresh }))];
    const f = fleet(rows);
    const first = failure(await Effect.runPromiseExit(createVm(createInput as never).pipe(Effect.provide(layer(f)))));
    expect(first).toBeInstanceOf(VmCreateWaitingError);
    expect((first as VmCreateWaitingError).state).toBe("waiting_for_address");
    expect(f.creates).toHaveLength(0);

    expect(await park(f)).toMatchObject({ checked: 1, parked: 1 });
    expect(f.destroyed).toEqual([rows[0]!.providerVmId!]);

    const retry = await Effect.runPromiseExit(createVm(createInput as never).pipe(Effect.provide(layer(f))));
    expect(Exit.isSuccess(retry)).toBe(true);
    expect(f.creates).toEqual(["image"]);
  });

  test("resume of a parked row at the cap waits, then restores once another parks, and the old id follows", async () => {
    const fresh = new Date(NOW - 3_600_000);
    const parkedFirst = row();
    const f = fleet([parkedFirst]);
    expect(await park(f)).toMatchObject({ parked: 1 });
    const snapshotId = release(f.rows[0])!.snapshotId;
    // The network refills: six other machines hold every address; one of them is old.
    const old = row({ updatedAt: new Date(NOW - 30 * 3_600_000) });
    f.rows.push(old, ...Array.from({ length: 5 }, () => row({ updatedAt: fresh })));

    const resumeInput = {
      userId: USER_ID,
      billingCustomerType: "user" as const,
      billingTeamId: TEAM_ID,
      billingPlanId: "free",
      maxActiveVms: null,
      teamIds: [TEAM_ID],
      providerVmId: parkedFirst.providerVmId!,
      waitForCapacity: true,
      now: () => NOW,
    };
    const waiting = failure(await Effect.runPromiseExit(resumeParkedVm(resumeInput).pipe(Effect.provide(layer(f)))));
    expect(waiting).toBeInstanceOf(VmCreateWaitingError);
    expect((waiting as VmCreateWaitingError).state).toBe("waiting_for_address");
    expect((waiting as VmCreateWaitingError).idempotencyKey).toBe(parkedRestoreIdempotencyKey(parkedFirst.id));
    expect(release(f.rows.find((r) => r.id === parkedFirst.id))?.state).toBe("parked");

    expect(await park(f)).toMatchObject({ parked: 1 });

    const entry = await Effect.runPromise(resumeParkedVm(resumeInput).pipe(Effect.provide(layer(f))));
    expect(f.creates).toEqual([snapshotId]);
    const retired = f.rows.find((r) => r.id === parkedFirst.id)!;
    expect(retired.status).toBe("destroyed");
    expect(release(retired)).toMatchObject({ state: "restored", successorProviderVmId: entry.providerVmId });

    const followed = await Effect.runPromise(requireUserVm({ userId: USER_ID, billingTeamId: TEAM_ID, teamIds: [TEAM_ID], providerVmId: parkedFirst.providerVmId! } as never).pipe(Effect.provide(layer(f))));
    expect(followed.providerVmId).toBe(entry.providerVmId);
  });
});
