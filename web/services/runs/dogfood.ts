import { defaultProviderId, getProvider } from "../vms/drivers";
import { resolveVmImage } from "../vms/images/resolver";
import { vmModelPlaneGatewayFor, vmModelPlaneRevoker } from "../vms/modelPlaneGateway";
import { isVmNotFoundError } from "../vms/errors";
import { isProviderDeletionConfirmed } from "../vms/providerErrors";
import { createVm, destroyVm, runVmWorkflow } from "../vms/workflows";
import type { VmEntitlements } from "../vms/entitlements";
import type { AuthedUser } from "../vms/auth";
import { CloudVmRunAdapter } from "../vms/cloudVmRunAdapter";
import { attachAttemptToRuntime, createRuntime, getRuntime, updateRuntime } from "../vms/runtimeRepository";
import {
  claimAttemptLease,
  claimExpiredAttemptCleanups,
  cloudVmRowLive,
  confirmSandboxVmDestroyed,
  deferAttemptCleanup,
  failAbandonedSandboxAttempts,
  finishAttemptCleanup,
  sandboxVmOwnedByAttempt,
  finalizeAttemptCancellation,
  forceFinalizeRunCancellation,
  ingestRunEvent,
  listActiveCloudVmAttempts,
  recordAttemptProviderHandle,
  renewAttemptLease,
  scheduleAttemptRetention,
  type RunSource,
} from "./repository";

/**
 * The first internal dogfood adapter deliberately goes through the existing
 * Cloud VM workflows. It does not create a second provider lifecycle or pass
 * provider credentials to the worker. The guest receives only an opaque,
 * immutable run spec and reports through the fenced event API.
 */
export async function launchCloudVmAttempt(input: {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
  readonly runId: string;
  readonly attemptId: string;
  readonly index: number;
  readonly source: RunSource;
  readonly recipe: string;
}): Promise<void> {
  const lease = await claimAttemptLease({
    runId: input.runId,
    attemptId: input.attemptId,
    workerId: `cloud-vm:${input.user.id}`,
    ttlMs: 15 * 60 * 1000,
  });
  const provider = defaultProviderId();
  let vmId: string | undefined;
  let lastAttemptSequence = 0;
  const runtime = await createRuntime({
    ownerTeamId: input.entitlements.billingTeamId,
    kind: "ephemeral",
    lifecycleState: "provisioning",
    idempotencyKey: `run:${input.runId}:attempt:${input.attemptId}:runtime`,
  });
  await attachAttemptToRuntime({
    ownerTeamId: input.entitlements.billingTeamId,
    runId: input.runId,
    attemptId: input.attemptId,
    runtimeId: runtime.id,
  });
  try {
    const selected = resolveVmImage(provider, undefined, process.env, { kind: "base" });
    const vm = await runVmWorkflow(createVm({
      userId: input.user.id,
      billingCustomerType: input.entitlements.billingCustomerType,
      billingTeamId: input.entitlements.billingTeamId,
      billingPlanId: input.entitlements.planId,
      maxActiveVms: input.entitlements.maxActiveVms,
      provider,
      image: selected.image,
      imageVersion: selected.imageVersion,
      imageSize: selected.size ?? undefined,
      perMachineHome: true,
      idempotencyKey: `run:${input.runId}:attempt:${input.attemptId}`,
      modelPlane: vmModelPlaneGatewayFor({ teamId: input.entitlements.billingTeamId, stackUserId: input.user.id }),
      origin: "create",
    }));
    const createdVmId = vm.providerVmId;
    vmId = createdVmId;
    const currentRuntime = await getRuntime({ ownerTeamId: input.entitlements.billingTeamId, runtimeId: runtime.id });
    if (currentRuntime) {
      await updateRuntime({
        ownerTeamId: input.entitlements.billingTeamId,
        runtimeId: runtime.id,
        lifecycleState: "running",
      });
    }
    const started = await ingestRunEvent({
      runId: input.runId,
      attemptId: input.attemptId,
      leaseToken: lease.leaseToken,
      leaseGeneration: lease.leaseGeneration,
      externalId: "attempt-started",
      attemptSequence: 0,
      kind: "attempt.started",
      payload: { provider, providerVmId: createdVmId },
    });
    void started;
    const prompt = `Work on immutable commit ${input.source.commit ?? ""} for ${input.source.repository ?? "the attached repository"}. ${input.recipe}`;
    const adapter = new CloudVmRunAdapter(getProvider(provider));
    const prepared = await adapter.prepareAttempt({
      runId: input.runId,
      attemptId: input.attemptId,
      index: input.index,
      vmId: createdVmId,
      agent: "codex",
      prompt,
      lease: { leaseId: lease.leaseToken, leaseEpoch: lease.leaseGeneration },
    });
    const attempt = await adapter.start(prepared);
    await recordAttemptProviderHandle({
      runId: input.runId,
      attemptId: input.attemptId,
      leaseToken: lease.leaseToken,
      leaseGeneration: lease.leaseGeneration,
      providerVmId: createdVmId,
      providerWorkspaceId: attempt.workspaceId,
      providerTerminalId: attempt.terminalId,
    });
    for await (const event of adapter.events(attempt)) {
      lastAttemptSequence = Math.max(lastAttemptSequence, event.seq);
      const currentLease = await renewAttemptLease({
        runId: input.runId,
        attemptId: input.attemptId,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
      });
      const terminal = event.kind === "state" && event.payload.status !== "running";
      await ingestRunEvent({
        runId: input.runId,
        attemptId: input.attemptId,
        leaseToken: currentLease.leaseToken,
        leaseGeneration: currentLease.leaseGeneration,
        externalId: event.eventId,
        attemptSequence: event.seq,
        kind: event.kind === "output"
          ? "attempt.output"
          : terminal
            ? event.payload.status === "succeeded" ? "attempt.succeeded" : "attempt.failed"
            : "attempt.started",
        payload: { providerVmId: createdVmId, ...event.payload },
      });
    }
  } catch (error) {
    try {
      const currentRuntime = await getRuntime({ ownerTeamId: input.entitlements.billingTeamId, runtimeId: runtime.id });
      if (currentRuntime) {
        await updateRuntime({
          ownerTeamId: input.entitlements.billingTeamId,
          runtimeId: runtime.id,
          lifecycleState: "failed",
        });
      }
    } catch (runtimeError) {
      console.error("[runs] failed to record runtime failure", runtimeError);
    }
    // A provider failure before the started event still needs a terminal event.
    // If the lease was fenced by another worker, preserve that worker's state.
    try {
      await ingestRunEvent({
        runId: input.runId,
        attemptId: input.attemptId,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "attempt-failed",
        attemptSequence: lastAttemptSequence + 1,
        kind: "attempt.failed",
        payload: { providerVmId: vmId, error: error instanceof Error ? error.message.slice(0, 500) : String(error).slice(0, 500) },
      });
    } catch (terminalError) {
      console.error("[runs] failed to record cloud VM attempt failure", terminalError);
    }
  } finally {
    if (vmId) {
      try {
        // Keep the VM and terminal attachable for a short, durable window.
        // A cron reaper claims the row after terminalRetainUntil and performs
        // provider teardown. This survives process restarts and deploys.
        await scheduleAttemptRetention({
          runId: input.runId,
          attemptId: input.attemptId,
          leaseToken: lease.leaseToken,
          leaseGeneration: lease.leaseGeneration,
          providerVmId: vmId,
        });
      } catch (retentionError) {
        console.error("[runs] cloud VM attempt retention scheduling failed", retentionError);
      }
    }
  }
}

/** Close active cloud terminals, fence their leases, and finish cancellation. */
export async function cancelActiveCloudVmAttempts(input: {
  readonly runId: string;
  readonly userId: string;
}): Promise<void> {
  const active = await listActiveCloudVmAttempts(input.runId, input.userId);
  const provider = defaultProviderId();
  await Promise.allSettled(active.map(async ({ attempt }) => {
    try {
      if (attempt.providerVmId && attempt.providerWorkspaceId && attempt.providerTerminalId && attempt.leaseToken !== null) {
        const adapter = new CloudVmRunAdapter(getProvider(provider));
        await adapter.cancel({
          provider: "cloud-vm",
          vmId: attempt.providerVmId,
          runId: input.runId,
          attemptId: attempt.id,
          index: attempt.ordinal,
          workspaceId: attempt.providerWorkspaceId,
          terminalId: attempt.providerTerminalId,
          workspaceKey: `cmux-run:${input.runId}:${attempt.id}:workspace`,
          terminalKey: `cmux-run:${input.runId}:${attempt.id}:terminal`,
          lease: { leaseId: attempt.leaseToken, leaseEpoch: attempt.leaseGeneration },
          replayed: false,
        });
      }
    } catch (error) {
      // Provider cancellation is best effort; the DB fence below must still
      // complete the Run so a lost guest never leaves it in cancelling.
      console.error("[runs] cloud VM attempt cancellation failed", error);
    } finally {
      await finalizeAttemptCancellation({
        runId: input.runId,
        attemptId: attempt.id,
        leaseToken: attempt.leaseToken,
        leaseGeneration: attempt.leaseGeneration,
      });
    }
  }));
  await forceFinalizeRunCancellation(input.runId, input.userId);
}

/** The provider's own strict destroy: true when it destroyed the VM or says it has no such machine. */
async function strictProviderDestroy(providerVmId: string): Promise<boolean> {
  try {
    await getProvider(defaultProviderId()).destroy(providerVmId, undefined, { strict: true });
    return true;
  } catch (providerError) {
    // Only the provider's own "no such machine" counts; an endpoint 404 is not proof.
    if (isProviderDeletionConfirmed(providerError)) return true;
    console.error("[runs] sandbox VM provider destroy failed", providerError);
    return false;
  }
}

/**
 * Reap completed cloud VMs after their terminal attach window expires. The cron pass first fails
 * sandboxed attempts whose launcher died, so their VMs are due in the same pass; `runId` scopes
 * an inline destroy to one Run (a sandbox's own teardown or its cancel).
 */
export async function reapExpiredCloudVmAttempts(input: { readonly limit?: number; readonly runId?: string } = {}): Promise<{ claimed: number; cleaned: number; errors: number }> {
  // The cron pass sweeps every Run; a scoped call (a cancel) adopts that Run's orphan VM only.
  try {
    await failAbandonedSandboxAttempts({ limit: input.limit, runId: input.runId });
  } catch (error) {
    console.error("[runs] abandoned sandbox sweep failed", error);
  }
  const claims = await claimExpiredAttemptCleanups(input);
  let cleaned = 0;
  let errors = 0;
  await Promise.allSettled(claims.map(async (claim) => {
    let succeeded = false;
    let deferred = false;
    // A handle let go without any destroy: never recorded as a confirmed destroy.
    let released = false;
    try {
      if (!claim.attempt.providerVmId) throw new Error("retained attempt has no provider VM id");
      await runVmWorkflow(destroyVm({
        userId: claim.userId,
        billingTeamId: claim.billingTeamId,
        teamIds: claim.billingTeamId ? [claim.billingTeamId] : undefined,
        providerVmId: claim.attempt.providerVmId,
        modelPlane: vmModelPlaneRevoker(),
        source: "user_request",
        requireConfirmedDeletion: claim.environment === "sandboxed",
      }));
      succeeded = true;
      cleaned += 1;
    } catch (error) {
      if (isVmNotFoundError(error) && claim.environment === "sandboxed" && claim.attempt.providerVmId
        && await cloudVmRowLive(claim.attempt.providerVmId).catch(() => true)) {
        // A sandbox's VM row is still up but this scope can't reach it: not proof it is gone.
        // Keep the obligation (the receipt reads it as pending) and retry it in 10 minutes.
        errors += 1;
        deferred = true;
        console.error("[runs] sandbox VM is still recorded but out of the reaper's scope", { attemptId: claim.attempt.id });
      } else if (isVmNotFoundError(error) && claim.environment === "sandboxed" && claim.attempt.providerVmId) {
        // The unscoped provider destroy below is only for the VM the launcher created for this
        // attempt; an id that only came from an event never reaches another tenant's VM.
        const providerVmId = claim.attempt.providerVmId;
        const owned = await sandboxVmOwnedByAttempt({ providerVmId, runId: claim.attempt.runId, attemptId: claim.attempt.id, userId: claim.userId })
          .catch((lookupError: unknown) => {
            console.error("[runs] sandbox VM ownership lookup failed", lookupError);
            return null;
          });
        if (owned === null) {
          // Ownership unknown: no provider call; keep the obligation and retry later.
          errors += 1;
          deferred = true;
        } else if (!owned) {
          // Nothing of this Run's to destroy: let the handle go, and confirm no destroy.
          succeeded = true;
          released = true;
          console.warn("[runs] sandbox attempt's VM id is not its own VM; released without a provider destroy", { attemptId: claim.attempt.id });
        } else {
          // Its own VM row is no longer live, but that is the control plane's view: ask the provider
          // itself, and treat the VM as gone only when it confirms (destroyed now, or not found).
          if (await strictProviderDestroy(providerVmId)) {
            succeeded = true;
            cleaned += 1;
          } else {
            errors += 1;
            deferred = true;
          }
        }
      } else if (isVmNotFoundError(error)) {
        // The VM is gone, or this run's user and billing scope can no longer reach it, so this
        // row can never destroy it. Leaving it claimable would fail it every minute and, with
        // claims oldest first, starve the rows behind it.
        succeeded = true;
        console.warn("[runs] retained cloud VM was already gone", { attemptId: claim.attempt.id });
      } else {
        errors += 1;
        // A sandbox's destroy that keeps failing is retried later, not at the head of every batch.
        deferred = claim.environment === "sandboxed";
        console.error("[runs] retained cloud VM cleanup failed", error);
      }
    } finally {
      // For a sandbox, succeeded means a strict destroy confirmed the VM is gone. Record that: the
      // orphan sweep adopts a marked VM until it is set, so a failed write costs one more destroy.
      if (succeeded && !released && claim.environment === "sandboxed" && claim.attempt.providerVmId) {
        await confirmSandboxVmDestroyed(claim.attempt.providerVmId).catch((error) => console.error("[runs] sandbox VM destroy confirmation not recorded", error));
      }
      if (deferred) await deferAttemptCleanup({ attemptId: claim.attempt.id, cleanupLeaseToken: claim.cleanupLeaseToken, delayMs: 10 * 60_000 });
      else await finishAttemptCleanup({ attemptId: claim.attempt.id, cleanupLeaseToken: claim.cleanupLeaseToken, succeeded });
    }
  }));
  return { claimed: claims.length, cleaned, errors };
}

export async function launchQueuedCloudVmAttempts(input: {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
  readonly runId: string;
  readonly attempts: ReadonlyArray<{ id: string; ordinal: number; status: string }>;
  readonly source: RunSource;
  readonly recipe: string;
}): Promise<void> {
  const queued = input.attempts.filter((attempt) => attempt.status === "queued");
  await Promise.allSettled(queued.map((attempt) => launchCloudVmAttempt({
    user: input.user,
    entitlements: input.entitlements,
    runId: input.runId,
    attemptId: attempt.id,
    index: attempt.ordinal,
    source: input.source,
    recipe: input.recipe,
  })));
}
