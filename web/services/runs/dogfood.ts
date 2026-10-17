import { defaultProviderId, getProvider } from "../vms/drivers";
import { resolveVmImage } from "../vms/images/resolver";
import { vmModelPlaneGatewayFor, vmModelPlaneRevoker } from "../vms/modelPlaneGateway";
import { createVm, destroyVm, runVmWorkflow } from "../vms/workflows";
import type { VmEntitlements } from "../vms/entitlements";
import type { AuthedUser } from "../vms/auth";
import { CloudVmRunAdapter } from "../vms/cloudVmRunAdapter";
import {
  claimAttemptLease,
  ingestRunEvent,
  renewAttemptLease,
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
        await runVmWorkflow(destroyVm({
          userId: input.user.id,
          billingTeamId: input.entitlements.billingTeamId,
          teamIds: input.user.teamIds,
          providerVmId: vmId,
          modelPlane: vmModelPlaneRevoker(),
          source: "user_request",
        }));
      } catch (cleanupError) {
        console.error("[runs] cloud VM attempt cleanup failed", cleanupError);
      }
    }
  }
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

