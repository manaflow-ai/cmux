import { defaultProviderId, getProvider } from "../vms/drivers";
import { resolveVmImage } from "../vms/images/resolver";
import { vmModelPlaneGatewayFor, vmModelPlaneRevoker } from "../vms/modelPlaneGateway";
import { isVmNotFoundError } from "../vms/errors";
import { createVm, destroyVm, runVmWorkflow } from "../vms/workflows";
import type { VmEntitlements } from "../vms/entitlements";
import type { AuthedUser } from "../vms/auth";
import { CloudVmRunAdapter } from "../vms/cloudVmRunAdapter";
import { attachAttemptToRuntime, createRuntime, getRuntime, updateRuntime } from "../vms/runtimeRepository";
import {
  claimAttemptLease,
  claimExpiredAttemptCleanups,
  finishAttemptCleanup,
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

/** Reap completed cloud VMs after their terminal attach window expires. */
export async function reapExpiredCloudVmAttempts(input: { readonly limit?: number } = {}): Promise<{ claimed: number; cleaned: number; errors: number }> {
  const claims = await claimExpiredAttemptCleanups(input);
  let cleaned = 0;
  let errors = 0;
  await Promise.allSettled(claims.map(async (claim) => {
    let succeeded = false;
    try {
      if (!claim.attempt.providerVmId) throw new Error("retained attempt has no provider VM id");
      await runVmWorkflow(destroyVm({
        userId: claim.userId,
        billingTeamId: claim.billingTeamId,
        teamIds: claim.billingTeamId ? [claim.billingTeamId] : undefined,
        providerVmId: claim.attempt.providerVmId,
        modelPlane: vmModelPlaneRevoker(),
        source: "user_request",
      }));
      succeeded = true;
      cleaned += 1;
    } catch (error) {
      if (isVmNotFoundError(error)) {
        // The VM is gone, or this run's user and billing scope can no longer reach it, so this
        // row can never destroy it. Leaving it claimable would fail it every minute and, with
        // claims oldest first, starve the rows behind it.
        succeeded = true;
        console.warn("[runs] retained cloud VM was already gone", { attemptId: claim.attempt.id });
      } else {
        errors += 1;
        console.error("[runs] retained cloud VM cleanup failed", error);
      }
    } finally {
      await finishAttemptCleanup({ attemptId: claim.attempt.id, cleanupLeaseToken: claim.cleanupLeaseToken, succeeded });
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

