import * as Effect from "effect/Effect";
import { assertVmCreateEnabled } from "../vms/config";
import type { AuthedUser } from "../vms/auth";
import {
  resolveVmEntitlements,
  type VmBillingTeamResolutionError,
} from "../vms/entitlements";
import type { ExecResult } from "../vms/drivers";
import { resolveVmImage } from "../vms/images/resolver";
import { createVm, destroyVm, execVm, runVmWorkflow, snapshotVm, type VmEntry } from "../vms/workflows";
import { findFreestyleActionSnapshotByName, type FreestyleActionSnapshot } from "./freestyleSnapshots";
import { actionRecipe, normalizeActionRef, normalizeActionRunMode, type ActionPort } from "./recipes";

type ActionRunnerDependencies = {
  readonly assertVmCreateEnabled: (provider: "freestyle") => void;
  readonly resolveVmImage: (
    provider: "freestyle",
    requestedImage?: string,
  ) => { readonly image: string; readonly imageVersion?: string | null };
  readonly resolveVmEntitlements: typeof resolveVmEntitlements;
  readonly findFreestyleActionSnapshotByName: typeof findFreestyleActionSnapshotByName;
  readonly createVm: (input: Parameters<typeof createVm>[0]) => unknown;
  readonly destroyVm: (input: Parameters<typeof destroyVm>[0]) => unknown;
  readonly execVm: (input: Parameters<typeof execVm>[0]) => unknown;
  readonly runVmWorkflow: (program: unknown) => Promise<unknown>;
  readonly snapshotVm: (input: Parameters<typeof snapshotVm>[0]) => unknown;
};

const defaultActionRunnerDependencies: ActionRunnerDependencies = {
  assertVmCreateEnabled,
  resolveVmImage,
  resolveVmEntitlements,
  findFreestyleActionSnapshotByName,
  createVm,
  destroyVm,
  execVm,
  runVmWorkflow: async (program) => runVmWorkflow(program as never),
  snapshotVm,
};

export type ActionRunRequest = {
  readonly action: unknown;
  readonly ref?: unknown;
  readonly mode?: unknown;
  readonly dryRun?: unknown;
  readonly keep?: unknown;
  readonly noCache?: unknown;
  readonly idempotencyKey?: unknown;
};

export type ActionRunResult = {
  readonly action: string;
  readonly title: string;
  readonly ref: string;
  readonly mode: "full" | "basic";
  readonly dryRun: boolean;
  readonly vmId?: string;
  readonly cache: {
    readonly hit: boolean;
  };
  readonly setupRan: boolean;
  readonly started: boolean;
  readonly ports: readonly ActionPort[];
  readonly instructions: readonly string[];
};

export class ActionRunError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message: string,
    public readonly action: string,
    public readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "ActionRunError";
  }
}

export function isActionRunError(err: unknown): err is ActionRunError {
  return err instanceof ActionRunError;
}

export async function runAction(input: {
  readonly request: ActionRunRequest;
  readonly user: AuthedUser;
  readonly requestedBillingTeamId?: string | null;
  readonly dependencies?: Partial<ActionRunnerDependencies>;
}): Promise<ActionRunResult> {
  const dependencies = {
    ...defaultActionRunnerDependencies,
    ...input.dependencies,
  };
  const actionId = typeof input.request.action === "string" ? input.request.action.trim() : "";
  if (!actionId) {
    throw new ActionRunError(
      "actions_invalid_request",
      400,
      "`action` is required.",
      "Run `cmux actions run hexclave/stack-auth:fresh-env`.",
      { field: "action" },
    );
  }
  const recipe = actionRecipe(actionId);
  if (!recipe) {
    throw new ActionRunError(
      "actions_unknown_action",
      404,
      "That action is not available.",
      "Run `cmux actions list` to see available actions.",
      { action: actionId },
    );
  }

  const ref = normalizeActionRef(input.request.ref, recipe.defaultRef);
  const mode = normalizeActionRunMode(input.request.mode);
  const dryRun = input.request.dryRun === true;
  const keep = input.request.keep === true;

  if (dryRun) {
    return {
      action: recipe.id,
      title: recipe.title,
      ref,
      mode,
      dryRun: true,
      cache: { hit: false },
      setupRan: false,
      started: false,
      ports: recipe.ports,
      instructions: dryRunInstructions(recipe.id),
    };
  }

  const baseImage = resolveActionBaseImage(dependencies);
  const cacheName = recipe.cacheName({ ref, mode, baseImage: baseImage.image });
  const setupScript = recipe.setupScript({ ref, mode });
  const startScript = recipe.startScript({ ref, mode });

  const entitlements = dependencies.resolveVmEntitlements(input.user, process.env, {
    requestedBillingTeamId: input.requestedBillingTeamId ?? null,
    requireTeam: true,
  });

  const idempotencyKey = typeof input.request.idempotencyKey === "string" && input.request.idempotencyKey.trim()
    ? input.request.idempotencyKey.trim().slice(0, 128)
    : undefined;

  const noCache = input.request.noCache === true;
  const cachedSnapshot = noCache ? null : await findCachedSnapshot({
    cacheName,
    action: recipe.id,
    dependencies,
  });
  const image = cachedSnapshot?.id ?? baseImage.image;
  const imageVersion = cachedSnapshot ? `actions:${recipe.cacheVersion}` : baseImage.imageVersion;
  const vm = await dependencies.runVmWorkflow(dependencies.createVm({
    userId: input.user.id,
    billingCustomerType: entitlements.billingCustomerType,
    billingTeamId: entitlements.billingTeamId,
    billingPlanId: entitlements.planId,
    maxActiveVms: entitlements.maxActiveVms,
    provider: "freestyle",
    image,
    imageVersion,
    idempotencyKey,
  })) as VmEntry;

  let setupRan = false;
  try {
    if (!cachedSnapshot) {
      await runCheckedExec({
        userId: input.user.id,
        vmId: vm.providerVmId,
        command: setupScript,
        timeoutMs: recipe.setupTimeoutMs,
        phase: "setup",
        keep,
        dependencies,
      });
      setupRan = true;
      try {
        await dependencies.runVmWorkflow(dependencies.snapshotVm({
          userId: input.user.id,
          providerVmId: vm.providerVmId,
          name: cacheName,
        }));
      } catch {
        console.warn("Cloud action setup cache snapshot failed; continuing with the live VM.", {
          action: recipe.id,
        });
      }
    }

    await runCheckedExec({
      userId: input.user.id,
      vmId: vm.providerVmId,
      command: startScript,
      timeoutMs: recipe.startTimeoutMs,
      phase: "start",
      keep,
      dependencies,
    });
  } catch (err) {
    if (!keep) {
      await dependencies.runVmWorkflow(dependencies.destroyVm({ userId: input.user.id, providerVmId: vm.providerVmId }))
        .catch(() => undefined);
    }
    if (isActionRunError(err)) throw err;
    throw new ActionRunError(
      "actions_run_failed",
      500,
      "The action VM could not finish setup.",
      keep
        ? `Run \`cmux vm ssh ${vm.providerVmId}\` to inspect the VM. Logs are under /workspace/.cmux-actions/logs.`
        : "Retry with `--keep` to preserve the VM for inspection. Logs are under /workspace/.cmux-actions/logs when the VM is kept.",
      { phase: "run", vmKept: keep },
    );
  }

  return {
    action: recipe.id,
    title: recipe.title,
    ref,
    mode,
    dryRun: false,
    vmId: vm.providerVmId,
    cache: {
      hit: !!cachedSnapshot,
    },
    setupRan,
    started: true,
    ports: recipe.ports,
    instructions: runInstructions(recipe.id, vm.providerVmId, recipe.ports),
  };
}

function resolveActionBaseImage(dependencies: ActionRunnerDependencies) {
  dependencies.assertVmCreateEnabled("freestyle");
  return dependencies.resolveVmImage("freestyle", undefined);
}

async function runCheckedExec(input: {
  readonly userId: string;
  readonly vmId: string;
  readonly command: string;
  readonly timeoutMs: number;
  readonly phase: "setup" | "start";
  readonly keep: boolean;
  readonly dependencies: ActionRunnerDependencies;
}) {
  const result = await input.dependencies.runVmWorkflow(input.dependencies.execVm({
    userId: input.userId,
    providerVmId: input.vmId,
    command: input.command,
    timeoutMs: input.timeoutMs,
  })) as ExecResult;
  if (result.exitCode === 0) return;
  const action = input.keep
    ? `Run \`cmux vm ssh ${input.vmId}\` to inspect the VM. Logs are under /workspace/.cmux-actions/logs.`
    : "Retry with `--keep` to preserve a failed VM for inspection. Logs are under /workspace/.cmux-actions/logs when the VM is kept.";
  throw new ActionRunError(
    `actions_${input.phase}_failed`,
    500,
    `The action ${input.phase} step failed.`,
    action,
    {
      phase: input.phase,
      exitCode: result.exitCode,
      vmKept: input.keep,
    },
  );
}

async function findCachedSnapshot(input: {
  readonly cacheName: string;
  readonly action: string;
  readonly dependencies: ActionRunnerDependencies;
}): Promise<FreestyleActionSnapshot | null> {
  try {
    return await Effect.runPromise(input.dependencies.findFreestyleActionSnapshotByName(input.cacheName));
  } catch (err) {
    console.error("Cloud action cache lookup failed", { action: input.action, error: err });
    throw new ActionRunError(
      "actions_cache_unavailable",
      503,
      "The saved setup layer is not available right now.",
      `Retry with \`cmux actions run ${input.action} --no-cache\` to rebuild it.`,
      { phase: "cache_lookup" },
    );
  }
}

function dryRunInstructions(action: string): readonly string[] {
  return [
    `Run \`cmux actions run ${action}\` to create the environment.`,
    "Use `--mode basic` for a smaller Stack Auth process set.",
  ];
}

function runInstructions(action: string, vmId: string, ports: readonly ActionPort[]): readonly string[] {
  return [
    `Attached VM: ${vmId}`,
    `Run \`cmux vm ssh ${vmId}\` to reopen the environment.`,
    ...ports.map((port) => `${port.name}: ${port.url}`),
    `Rebuild from scratch with \`cmux actions run ${action} --no-cache\`.`,
  ];
}

export function actionRunTeamErrorResponseDetails(err: VmBillingTeamResolutionError): {
  readonly error: string;
  readonly status: number;
  readonly message: string;
  readonly action: string;
} {
  if (err.code === "vm_billing_team_not_found") {
    return {
      error: "actions_team_not_found",
      status: err.status,
      message: "That team is not available for this account.",
      action: "Switch to a team you belong to, or run `cmux auth login` again and retry.",
    };
  }
  return {
    error: "actions_team_required",
    status: err.status,
    message: "cmux needs to know which team should own this action VM.",
    action: "Select a team in cmux, or run `cmux auth status` to check the signed-in account.",
  };
}
