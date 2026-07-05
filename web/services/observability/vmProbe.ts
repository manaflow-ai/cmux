import { and, eq, inArray, isNotNull, like, lt } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVmProbeState, cloudVms } from "../../db/schema";
import { assertVmCreateEnabled } from "../vms/config";
import { defaultProviderId, type ExecResult, type ProviderId } from "../vms/drivers";
import { maxActiveVmsForPlan } from "../vms/entitlements";
import {
  isVmCreateCreditsInsufficientError,
  isVmCreateDisabledError,
  vmWorkflowErrorCause,
} from "../vms/errors";
import {
  imageUsesBakedFreestyleSignedAdmin,
  resolveVmImage,
} from "../vms/images/resolver";
import {
  createVm,
  destroyVm,
  execVm,
  getVm,
  runVmWorkflow,
  type VmEntry,
} from "../vms/workflows";
import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";

const PROBE_STATE_KEY = "default";
const PROBE_IDEMPOTENCY_PREFIX = "cmux-probe-";
const PROBE_OK = "cmux-probe-ok";

type ProbeStepName = "create" | "status" | "exec" | "destroy";
type ProbeStepOutcome = "ok" | "error";

export type VmProbeAlertInput = AlertInput;

export type VmProbeStepSummary = {
  readonly step: ProbeStepName;
  readonly outcome: ProbeStepOutcome;
  readonly ms: number;
  readonly budgetMs: number;
  readonly budgetExceeded: boolean;
  readonly errorCode?: string;
  readonly errorMessage?: string;
};

export type VmProbeRunSummary =
  | { readonly skipped: "probe_not_configured" }
  | { readonly skipped: "create_disabled"; readonly reason: string }
  | {
      readonly status: "success" | "failure";
      readonly startedAt: string;
      readonly finishedAt: string;
      readonly provider: ProviderId | null;
      readonly imageVersion: string | null;
      readonly billingTeamId: string | null;
      readonly vmId: string | null;
      readonly steps: readonly VmProbeStepSummary[];
      readonly staleReap: VmProbeStaleReapSummary;
      readonly state: {
        readonly lastRunAt: string;
        readonly lastSuccessAt: string | null;
        readonly consecutiveFailures: number;
      };
      readonly stateWriteError?: {
        readonly code: string;
        readonly message: string;
      };
    };

export type VmProbeFreshness = {
  readonly lastSuccessAt: string | null;
  readonly stale: boolean;
};

export type VmProbePersistedState = {
  readonly key: string;
  readonly lastRunAt: Date | null;
  readonly lastSuccessAt: Date | null;
  readonly consecutiveFailures: number;
  readonly lastErrorCode: string | null;
  readonly lastErrorMessage: string | null;
};

type VmProbeStaleVm = {
  readonly id: string;
  readonly providerVmId: string;
};

export type VmProbeStaleReapSummary = {
  readonly checkedBefore: string;
  readonly found: number;
  readonly destroyed: readonly string[];
  readonly failed: readonly { readonly vmId: string; readonly errorCode: string; readonly errorMessage: string }[];
};

type VmProbeStore = {
  readonly getState: () => Promise<VmProbePersistedState | null>;
  readonly recordResult: (input: {
    readonly now: Date;
    readonly success: boolean;
    readonly errorCode: string | null;
    readonly errorMessage: string | null;
    readonly previousState: VmProbePersistedState | null;
  }) => Promise<VmProbePersistedState>;
  readonly listStaleProbeVms: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly before: Date;
  }) => Promise<readonly VmProbeStaleVm[]>;
};

type VmProbeWorkflows = {
  readonly create: (input: Parameters<typeof createVm>[0]) => Promise<VmEntry>;
  readonly get: (input: Parameters<typeof getVm>[0]) => Promise<VmEntry>;
  readonly exec: (input: Parameters<typeof execVm>[0]) => Promise<ExecResult>;
  readonly destroy: (input: Parameters<typeof destroyVm>[0]) => Promise<void>;
};

type VmProbeClock = {
  readonly now: () => Date;
  readonly delay: (ms: number) => Promise<void>;
};

type SendProbeAlert = (input: VmProbeAlertInput) => Promise<AlertResult>;

export async function runVmProbe(options: {
  readonly db?: ReturnType<typeof cloudDb>;
  readonly env?: Record<string, string | undefined>;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: SendProbeAlert;
  readonly store?: VmProbeStore;
  readonly workflows?: VmProbeWorkflows;
  readonly clock?: VmProbeClock;
} = {}): Promise<VmProbeRunSummary> {
  const env = options.env ?? process.env;
  const clock = options.clock ?? systemClock;
  const store = options.store ?? makeVmProbeStore(options.db ?? cloudDb());
  const workflows = options.workflows ?? defaultWorkflows;
  const send = options.sendAlert ?? ((input) => sendAlert(input, { fetch: options.fetch, env }));
  const startedAt = clock.now();
  const previousState = await safeGetState(store);
  const steps: VmProbeStepSummary[] = [];
  let configured: ProbeConfig;
  try {
    const config = probeConfig(env);
    if (!config) return { skipped: "probe_not_configured" };
    configured = config;
  } catch (error) {
    if (isVmCreateDisabledError(error)) {
      return { skipped: "create_disabled", reason: error.reason };
    }
    return finishEarlyFailure({
      phase: "config",
      error,
      store,
      previousState,
      send,
      clock,
      startedAt,
      steps,
      staleReap: emptyStaleReap(startedAt),
      configured: null,
    });
  }

  let staleReap: VmProbeStaleReapSummary;
  try {
    staleReap = await reapStaleProbeVms({
      config: configured,
      store,
      workflows,
      send,
      clock,
    });
  } catch (error) {
    return finishEarlyFailure({
      phase: "stale_reap",
      error,
      store,
      previousState,
      send,
      clock,
      startedAt,
      steps,
      staleReap: emptyStaleReap(startedAt),
      configured,
    });
  }

  let vmId: string | null = null;
  let failure: { code: string; message: string; step: ProbeStepName } | null = null;
  let createCreditsExhausted = false;
  let leakAlertSent = false;

  try {
    const created = await runStep("create", configured.createBudgetMs, clock, steps, () =>
      workflows.create({
        userId: configured.userId,
        billingCustomerType: configured.billingCustomerType,
        billingTeamId: configured.billingTeamId,
        billingPlanId: configured.billingPlanId,
        maxActiveVms: configured.maxActiveVms,
        provider: configured.provider,
        image: configured.image,
        imageVersion: configured.imageVersion,
        idempotencyKey: `${PROBE_IDEMPOTENCY_PREFIX}${startedAt.toISOString()}`,
        bakedFreestyleSignedAdmin: imageUsesBakedFreestyleSignedAdmin(configured.provider, configured.image),
      })
    );
    vmId = created.providerVmId;
    recordBudgetFailure(steps.at(-1), "create");

    await runStep("status", configured.statusBudgetMs, clock, steps, () =>
      pollUntilRunning({
        workflows,
        clock,
        config: configured,
        vmId: created.providerVmId,
      })
    );
    recordBudgetFailure(steps.at(-1), "status");

    const execResult = await runStep("exec", configured.execBudgetMs, clock, steps, () =>
      workflows.exec({
        userId: configured.userId,
        billingTeamId: configured.billingTeamId,
        providerVmId: created.providerVmId,
        command: `echo ${PROBE_OK}`,
        timeoutMs: configured.execBudgetMs,
      })
    );
    if (execResult.exitCode !== 0 || execResult.stdout.trim() !== PROBE_OK) {
      throw probeStepError("exec", "vm_probe_exec_unexpected_output", [
        `exitCode=${execResult.exitCode}`,
        `stdout=${singleLine(execResult.stdout)}`,
        `stderr=${singleLine(execResult.stderr)}`,
      ].join(" "));
    }
    recordBudgetFailure(steps.at(-1), "exec");
  } catch (error) {
    const summary = errorSummary(error);
    const step = stepFromError(error) ?? stepFromLastError(steps) ?? "create";
    failure = { ...summary, step };
    createCreditsExhausted = step === "create" && isVmCreateCreditsInsufficientError(vmWorkflowErrorCause(error) ?? error);
    if (steps.length === 0 || steps.at(-1)?.outcome !== "error") {
      steps.push({
        step,
        outcome: "error",
        ms: 0,
        budgetMs: budgetForStep(configured, step),
        budgetExceeded: false,
        errorCode: summary.code,
        errorMessage: summary.message,
      });
    }
  } finally {
    if (vmId) {
      const destroyVmId = vmId;
      try {
        await runStep("destroy", configured.destroyBudgetMs, clock, steps, () =>
          workflows.destroy({
            userId: configured.userId,
            billingTeamId: configured.billingTeamId,
            providerVmId: destroyVmId,
          })
        );
        recordBudgetFailure(steps.at(-1), "destroy");
      } catch (error) {
        const summary = errorSummary(error);
        if (!failure) {
          failure = { ...summary, step: "destroy" };
        }
        await sendLeakAlert(send, summary, destroyVmId, stepMs(steps, "destroy"));
        leakAlertSent = true;
      }
    }
  }

  const budgetFailure = steps.find((step) => step.budgetExceeded);
  if (!failure && budgetFailure) {
    failure = {
      step: budgetFailure.step,
      code: "vm_probe_budget_exceeded",
      message: `${budgetFailure.step} took ${budgetFailure.ms}ms; budget is ${budgetFailure.budgetMs}ms`,
    };
  }

  if (failure) {
    if (createCreditsExhausted) {
      await sendCreditsAlert(send, failure, stepMs(steps, "create"));
    } else if (failure.step !== "destroy" || !leakAlertSent) {
      await sendStepAlert(send, failure, vmId, stepMs(steps, failure.step));
    }
  }

  const finishedAt = clock.now();
  const success = !failure;
  const persistedResult = await recordProbeResultSafely(store, {
    now: finishedAt,
    success,
    errorCode: failure?.code ?? null,
    errorMessage: failure?.message ?? null,
    previousState,
  });
  if (success && persistedResult.ok && (previousState?.consecutiveFailures ?? 0) > 0) {
    await send({
      key: "vm-probe-recovered",
      title: "Cloud VM synthetic probe recovered",
      body: `The active Cloud VM probe succeeded after ${previousState?.consecutiveFailures ?? 0} consecutive failure(s).`,
      severity: "warning",
    });
  }
  const persisted = persistedResult.state;

  return {
    status: success ? "success" : "failure",
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    provider: configured.provider,
    imageVersion: configured.imageVersion,
    billingTeamId: configured.billingTeamId,
    vmId,
    steps,
    staleReap,
    state: {
      lastRunAt: isoOrNow(persisted.lastRunAt, finishedAt),
      lastSuccessAt: persisted.lastSuccessAt?.toISOString() ?? null,
      consecutiveFailures: persisted.consecutiveFailures,
    },
    ...(persistedResult.ok ? {} : { stateWriteError: persistedResult.error }),
  };

  function recordBudgetFailure(step: VmProbeStepSummary | undefined, stepName: ProbeStepName) {
    if (!step?.budgetExceeded || failure) return;
    failure = {
      step: stepName,
      code: "vm_probe_budget_exceeded",
      message: `${stepName} took ${step.ms}ms; budget is ${step.budgetMs}ms`,
    };
  }
}

export async function getVmProbeFreshness(options: {
  readonly db?: ReturnType<typeof cloudDb>;
  readonly env?: Record<string, string | undefined>;
  readonly now?: Date;
  readonly store?: Pick<VmProbeStore, "getState">;
} = {}): Promise<VmProbeFreshness> {
  const env = options.env ?? process.env;
  const now = options.now ?? new Date();
  const staleMs = positiveIntegerEnv(env.CMUX_VM_PROBE_FRESHNESS_STALE_MS, 45 * 60 * 1000);
  const store = options.store ?? makeVmProbeStore(options.db ?? cloudDb());
  const state = await store.getState();
  const lastSuccessAt = state?.lastSuccessAt ?? null;
  return {
    lastSuccessAt: lastSuccessAt?.toISOString() ?? null,
    stale: !lastSuccessAt || now.getTime() - lastSuccessAt.getTime() > staleMs,
  };
}

async function finishEarlyFailure(input: {
  readonly phase: "config" | "stale_reap";
  readonly error: unknown;
  readonly store: VmProbeStore;
  readonly previousState: VmProbePersistedState | null;
  readonly send: SendProbeAlert;
  readonly clock: VmProbeClock;
  readonly startedAt: Date;
  readonly steps: readonly VmProbeStepSummary[];
  readonly staleReap: VmProbeStaleReapSummary;
  readonly configured: ProbeConfig | null;
}): Promise<VmProbeRunSummary> {
  const summary = errorSummary(input.error);
  await sendRunFailureAlert(input.send, input.phase, summary);
  const finishedAt = input.clock.now();
  const persistedResult = await recordProbeResultSafely(input.store, {
    now: finishedAt,
    success: false,
    errorCode: summary.code,
    errorMessage: summary.message,
    previousState: input.previousState,
  });
  const persisted = persistedResult.state;
  return {
    status: "failure",
    startedAt: input.startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    provider: input.configured?.provider ?? null,
    imageVersion: input.configured?.imageVersion ?? null,
    billingTeamId: input.configured?.billingTeamId ?? null,
    vmId: null,
    steps: input.steps,
    staleReap: input.staleReap,
    state: {
      lastRunAt: isoOrNow(persisted.lastRunAt, finishedAt),
      lastSuccessAt: persisted.lastSuccessAt?.toISOString() ?? null,
      consecutiveFailures: persisted.consecutiveFailures,
    },
    ...(persistedResult.ok ? {} : { stateWriteError: persistedResult.error }),
  };
}

async function recordProbeResultSafely(
  store: VmProbeStore,
  input: {
    readonly now: Date;
    readonly success: boolean;
    readonly errorCode: string | null;
    readonly errorMessage: string | null;
    readonly previousState: VmProbePersistedState | null;
  },
): Promise<
  | { readonly ok: true; readonly state: VmProbePersistedState }
  | {
      readonly ok: false;
      readonly state: VmProbePersistedState;
      readonly error: { readonly code: string; readonly message: string };
    }
> {
  try {
    return {
      ok: true,
      state: await store.recordResult(input),
    };
  } catch (error) {
    const summary = errorSummary(error);
    const previous = input.previousState;
    return {
      ok: false,
      state: {
        key: PROBE_STATE_KEY,
        lastRunAt: input.now,
        lastSuccessAt: input.success ? previous?.lastSuccessAt ?? null : previous?.lastSuccessAt ?? null,
        consecutiveFailures: input.success
          ? previous?.consecutiveFailures ?? 0
          : (previous?.consecutiveFailures ?? 0) + 1,
        lastErrorCode: input.success ? previous?.lastErrorCode ?? null : input.errorCode,
        lastErrorMessage: input.success ? previous?.lastErrorMessage ?? null : input.errorMessage,
      },
      error: summary,
    };
  }
}

function emptyStaleReap(now: Date): VmProbeStaleReapSummary {
  return {
    checkedBefore: now.toISOString(),
    found: 0,
    destroyed: [],
    failed: [],
  };
}

function makeVmProbeStore(db: ReturnType<typeof cloudDb>): VmProbeStore {
  return {
    getState: async () => {
      const [row] = await db
        .select()
        .from(cloudVmProbeState)
        .where(eq(cloudVmProbeState.key, PROBE_STATE_KEY))
        .limit(1);
      return row ?? null;
    },
    recordResult: async (input) => {
      const lastSuccessAt = input.success
        ? input.now
        : input.previousState?.lastSuccessAt ?? null;
      const consecutiveFailures = input.success
        ? 0
        : (input.previousState?.consecutiveFailures ?? 0) + 1;
      const values = {
        key: PROBE_STATE_KEY,
        lastRunAt: input.now,
        lastSuccessAt,
        consecutiveFailures,
        lastErrorCode: input.success ? null : input.errorCode,
        lastErrorMessage: input.success ? null : input.errorMessage,
        updatedAt: input.now,
      };
      const [row] = await db
        .insert(cloudVmProbeState)
        .values(values)
        .onConflictDoUpdate({
          target: cloudVmProbeState.key,
          set: values,
        })
        .returning();
      if (!row) throw new Error("cloud_vm_probe_state upsert returned no row");
      return row;
    },
    listStaleProbeVms: async (input) => {
      return db
        .select({
          id: cloudVms.id,
          providerVmId: cloudVms.providerVmId,
        })
        .from(cloudVms)
        .where(and(
          eq(cloudVms.userId, input.userId),
          eq(cloudVms.billingTeamId, input.billingTeamId),
          like(cloudVms.idempotencyKey, `${PROBE_IDEMPOTENCY_PREFIX}%`),
          inArray(cloudVms.status, ["provisioning", "running", "paused"]),
          isNotNull(cloudVms.providerVmId),
          lt(cloudVms.createdAt, input.before),
        ))
        .limit(20) as Promise<readonly VmProbeStaleVm[]>;
    },
  };
}

const defaultWorkflows: VmProbeWorkflows = {
  create: (input) => runVmWorkflow(createVm(input)),
  get: (input) => runVmWorkflow(getVm(input)),
  exec: (input) => runVmWorkflow(execVm(input)),
  destroy: (input) => runVmWorkflow(destroyVm(input)),
};

const systemClock: VmProbeClock = {
  now: () => new Date(),
  delay: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
};

async function runStep<A>(
  step: ProbeStepName,
  budgetMs: number,
  clock: VmProbeClock,
  steps: VmProbeStepSummary[],
  run: () => Promise<A>,
): Promise<A> {
  const start = clock.now().getTime();
  try {
    const result = await run();
    const ms = Math.max(0, clock.now().getTime() - start);
    steps.push({ step, outcome: "ok", ms, budgetMs, budgetExceeded: ms > budgetMs });
    return result;
  } catch (error) {
    const ms = Math.max(0, clock.now().getTime() - start);
    const summary = errorSummary(error);
    steps.push({
      step,
      outcome: "error",
      ms,
      budgetMs,
      budgetExceeded: ms > budgetMs,
      errorCode: summary.code,
      errorMessage: summary.message,
    });
    throw error;
  }
}

async function pollUntilRunning(input: {
  readonly workflows: VmProbeWorkflows;
  readonly clock: VmProbeClock;
  readonly config: ProbeConfig;
  readonly vmId: string;
}): Promise<VmEntry> {
  const deadline = input.clock.now().getTime() + input.config.statusBudgetMs;
  let last: VmEntry | null = null;
  for (;;) {
    last = await input.workflows.get({
      userId: input.config.userId,
      billingTeamId: input.config.billingTeamId,
      providerVmId: input.vmId,
    });
    if (last.status === "running") return last;
    if (input.clock.now().getTime() >= deadline) {
      throw probeStepError("status", "vm_probe_status_timeout", `status stayed ${last.status}`);
    }
    await input.clock.delay(Math.min(input.config.statusPollMs, Math.max(1, deadline - input.clock.now().getTime())));
  }
}

async function reapStaleProbeVms(input: {
  readonly config: ProbeConfig;
  readonly store: VmProbeStore;
  readonly workflows: VmProbeWorkflows;
  readonly send: SendProbeAlert;
  readonly clock: VmProbeClock;
}): Promise<VmProbeStaleReapSummary> {
  const before = new Date(input.clock.now().getTime() - input.config.staleReapMs);
  const stale = await input.store.listStaleProbeVms({
    userId: input.config.userId,
    billingTeamId: input.config.billingTeamId,
    before,
  });
  const destroyed: string[] = [];
  const failed: { vmId: string; errorCode: string; errorMessage: string }[] = [];
  for (const vm of stale) {
    try {
      await input.workflows.destroy({
        userId: input.config.userId,
        billingTeamId: input.config.billingTeamId,
        providerVmId: vm.providerVmId,
      });
      destroyed.push(vm.providerVmId);
    } catch (error) {
      const summary = errorSummary(error);
      failed.push({ vmId: vm.providerVmId, errorCode: summary.code, errorMessage: summary.message });
    }
  }
  if (stale.length > 0 || failed.length > 0) {
    await input.send({
      key: "vm-probe-stale-reap",
      title: "Cloud VM probe reaped stale synthetic VMs",
      body: [
        `Found ${stale.length} stale probe VM(s) older than ${input.config.staleReapMs}ms.`,
        `Destroyed: ${destroyed.length ? destroyed.join(", ") : "none"}.`,
        failed.length ? `Failed: ${failed.map((item) => `${item.vmId}:${item.errorCode}`).join(", ")}.` : "",
      ].filter(Boolean).join(" "),
      severity: failed.length ? "critical" : "warning",
    });
  }
  return {
    checkedBefore: before.toISOString(),
    found: stale.length,
    destroyed,
    failed,
  };
}

async function safeGetState(store: VmProbeStore): Promise<VmProbePersistedState | null> {
  try {
    return await store.getState();
  } catch {
    return null;
  }
}

function sendStepAlert(
  send: SendProbeAlert,
  failure: { readonly step: ProbeStepName; readonly code: string; readonly message: string },
  vmId: string | null,
  latencyMs: number,
) {
  return send({
    key: "vm-probe-step-failed",
    title: "Cloud VM synthetic probe failed",
    body: [
      `Step: ${failure.step}.`,
      `Code: ${failure.code}.`,
      `Message: ${failure.message}.`,
      `Latency: ${latencyMs}ms.`,
      `VM id: ${vmId ?? "none"}.`,
    ].join(" "),
    severity: "critical",
  });
}

function sendCreditsAlert(
  send: SendProbeAlert,
  failure: { readonly code: string; readonly message: string },
  latencyMs: number,
) {
  return send({
    key: "vm-probe-credits-exhausted",
    title: "Cloud VM probe credits exhausted",
    body: [
      "The synthetic probe could not create a VM because monitor account credits are exhausted.",
      `Code: ${failure.code}.`,
      `Message: ${failure.message}.`,
      `Latency: ${latencyMs}ms.`,
    ].join(" "),
    severity: "warning",
  });
}

function sendLeakAlert(
  send: SendProbeAlert,
  failure: { readonly code: string; readonly message: string },
  vmId: string,
  latencyMs: number,
) {
  return send({
    key: "vm-probe-destroy-failed",
    title: "Cloud VM synthetic probe leaked a VM",
    body: [
      "Destroy failed after the synthetic probe created a VM.",
      `VM id: ${vmId}.`,
      `Code: ${failure.code}.`,
      `Message: ${failure.message}.`,
      `Latency: ${latencyMs}ms.`,
    ].join(" "),
    severity: "critical",
  });
}

function sendRunFailureAlert(
  send: SendProbeAlert,
  phase: "config" | "stale_reap",
  failure: { readonly code: string; readonly message: string },
) {
  return send({
    key: "vm-probe-run-failed",
    title: "Cloud VM synthetic probe could not start",
    body: [
      `Phase: ${phase}.`,
      `Code: ${failure.code}.`,
      `Message: ${failure.message}.`,
    ].join(" "),
    severity: "critical",
  });
}

type ProbeConfig = {
  readonly userId: string;
  readonly billingTeamId: string;
  readonly billingCustomerType: "team" | "user";
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly createBudgetMs: number;
  readonly statusBudgetMs: number;
  readonly execBudgetMs: number;
  readonly destroyBudgetMs: number;
  readonly statusPollMs: number;
  readonly staleReapMs: number;
};

function probeConfig(env: Record<string, string | undefined>): ProbeConfig | null {
  const userId = env.CMUX_VM_PROBE_USER_ID?.trim();
  if (!userId) return null;
  const billingTeamId = env.CMUX_VM_PROBE_TEAM_ID?.trim() || userId;
  const billingCustomerType = env.CMUX_VM_PROBE_TEAM_ID?.trim() ? "team" : "user";
  const billingPlanId = env.CMUX_VM_PROBE_PLAN_ID?.trim() || env.CMUX_VM_DEFAULT_PLAN?.trim() || "free";
  const provider = providerEnv(env.CMUX_VM_PROBE_PROVIDER) ?? defaultProviderId();
  assertVmCreateEnabled(provider, env);
  const imageSelection = resolveVmImage(provider, env.CMUX_VM_PROBE_IMAGE, env);
  return {
    userId,
    billingTeamId,
    billingCustomerType,
    billingPlanId,
    maxActiveVms: positiveIntegerEnv(env.CMUX_VM_PROBE_MAX_ACTIVE_VMS, maxActiveVmsForPlan(billingPlanId, env)),
    provider,
    image: imageSelection.image,
    imageVersion: imageSelection.imageVersion,
    createBudgetMs: positiveIntegerEnv(env.CMUX_VM_PROBE_CREATE_TIMEOUT_MS, 120_000),
    statusBudgetMs: positiveIntegerEnv(env.CMUX_VM_PROBE_STATUS_TIMEOUT_MS, 60_000),
    execBudgetMs: positiveIntegerEnv(env.CMUX_VM_PROBE_EXEC_TIMEOUT_MS, 30_000),
    destroyBudgetMs: positiveIntegerEnv(env.CMUX_VM_PROBE_DESTROY_TIMEOUT_MS, 60_000),
    statusPollMs: positiveIntegerEnv(env.CMUX_VM_PROBE_STATUS_POLL_MS, 5_000),
    staleReapMs: positiveIntegerEnv(env.CMUX_VM_PROBE_STALE_REAP_MS, 60 * 60 * 1000),
  };
}

function providerEnv(value: string | undefined): ProviderId | null {
  const trimmed = value?.trim();
  return trimmed === "e2b" || trimmed === "freestyle" || trimmed === "daytona" ? trimmed : null;
}

function positiveIntegerEnv(value: string | undefined, fallback: number): number {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return fallback;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function budgetForStep(config: ProbeConfig, step: ProbeStepName): number {
  switch (step) {
    case "create":
      return config.createBudgetMs;
    case "status":
      return config.statusBudgetMs;
    case "exec":
      return config.execBudgetMs;
    case "destroy":
      return config.destroyBudgetMs;
  }
}

function errorSummary(error: unknown): { readonly code: string; readonly message: string } {
  const workflowError = vmWorkflowErrorCause(error) ?? error;
  if (workflowError && typeof workflowError === "object") {
    const tag = (workflowError as { _tag?: unknown })._tag;
    if (typeof tag === "string") {
      return { code: errorCodeForTag(tag), message: workflowErrorMessage(workflowError) };
    }
    const code = (workflowError as { code?: unknown }).code;
    if (typeof code === "string") {
      return { code, message: errorMessage(workflowError) };
    }
  }
  return { code: "vm_probe_error", message: errorMessage(error) };
}

function errorCodeForTag(tag: string): string {
  switch (tag) {
    case "VmCreateCreditsInsufficientError":
      return "vm_create_credits_insufficient";
    case "VmProviderOperationError":
      return "vm_cloud_service_unavailable";
    case "VmCreateFailedError":
      return "vm_create_failed";
    case "VmDatabaseError":
      return "vm_cloud_state_unavailable";
    case "VmBillingError":
      return "vm_billing_unavailable";
    default:
      return tag.replace(/^Vm/, "vm_").replace(/Error$/, "").replace(/[A-Z]/g, (char) => `_${char.toLowerCase()}`).replace(/__+/g, "_");
  }
}

function workflowErrorMessage(error: object): string {
  const cause = (error as { cause?: unknown }).cause;
  if (cause) return errorMessage(cause);
  const message = (error as { message?: unknown }).message;
  return typeof message === "string" && message ? message : String((error as { _tag?: unknown })._tag ?? "unknown error");
}

function probeStepError(step: ProbeStepName, code: string, message: string): Error {
  const error = new Error(message) as Error & { code: string; step: ProbeStepName };
  error.code = code;
  error.step = step;
  return error;
}

function stepFromError(error: unknown): ProbeStepName | null {
  const step = (error as { step?: unknown } | null)?.step;
  return step === "create" || step === "status" || step === "exec" || step === "destroy" ? step : null;
}

function stepFromLastError(steps: readonly VmProbeStepSummary[]): ProbeStepName | null {
  const step = steps.at(-1);
  return step?.outcome === "error" ? step.step : null;
}

function stepMs(steps: readonly VmProbeStepSummary[], step: ProbeStepName): number {
  return steps.findLast((candidate) => candidate.step === step && candidate.ms > 0)?.ms ??
    steps.findLast((candidate) => candidate.step === step)?.ms ??
    0;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function singleLine(value: string): string {
  return value.replace(/\s+/g, " ").trim().slice(0, 200);
}

function isoOrNow(date: Date | null, now: Date): string {
  return (date ?? now).toISOString();
}
