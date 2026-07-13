import type { AuthedUser } from "../../../../services/vms/auth";
import { assertVmCreateEnabled } from "../../../../services/vms/config";
import { defaultProviderId, type ProviderId } from "../../../../services/vms/drivers";
import {
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../../../../services/vms/entitlements";
import {
  isVmCreateCreditsInsufficientError,
  isVmCreateDisabledError,
  isVmCreateFailedError,
  isVmCreateInProgressError,
  isVmImageConfigError,
  isVmLimitExceededError,
} from "../../../../services/vms/errors";
import {
  imageUsesBakedFreestyleSignedAdmin,
  resolveVmImage,
} from "../../../../services/vms/images/resolver";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmBillingTeamErrorResponse,
  vmErrorResponse,
  vmWorkflowErrorResponse,
  vmRequiresProResponse,
} from "../../../../services/vms/routeHelpers";
import { VmTimingRecorder } from "../../../../services/vms/timings";
import {
  openBaseVm,
  resetBaseVm,
  runVmWorkflow,
  type BaseVmEntry,
} from "../../../../services/vms/workflows";

type BaseOperation = "open" | "reset";

export async function runBaseRoute(input: {
  readonly request: Request;
  readonly user: AuthedUser;
  readonly operation: BaseOperation;
  readonly timing: VmTimingRecorder;
}): Promise<Response> {
  const parsed = await parseBaseRequest(input.request, input.operation);
  if (!parsed.ok) return parsed.response;

  const requestedBillingTeamId = parsed.body.billingTeamId || requestedVmTeamIdFromRequest(input.request);
  let entitlements;
  try {
    entitlements = resolveVmEntitlements(input.user, process.env, {
      requestedBillingTeamId,
      requireTeam: false,
    });
  } catch (err) {
    if (isVmBillingTeamResolutionError(err)) return vmBillingTeamErrorResponse(err);
    throw err;
  }

  if (isVmProGateBlocked(entitlements)) {
    return vmRequiresProResponse();
  }

  const provider = parsed.body.provider ?? defaultProviderId();
  let imageSelection;
  try {
    assertVmCreateEnabled(provider);
    imageSelection = resolveVmImage(provider, parsed.body.image);
  } catch (err) {
    if (isVmCreateDisabledError(err)) {
      return vmErrorResponse({
        error: "vm_create_disabled",
        status: 503,
        message: "Cloud VM creation is disabled for this environment.",
        action: "Ask an admin to enable Cloud VM creation, then retry.",
        reason: "Cloud VM creation is disabled.",
        phase: "create",
        retryable: true,
      });
    }
    if (isVmImageConfigError(err)) {
      return vmErrorResponse({
        error: "vm_image_config_error",
        status: 503,
        message: "The Cloud VM image is not available in this environment.",
        action: "Retry in a moment. If it keeps failing, contact support so we can check the Cloud VM image configuration.",
        reason: "Cloud VM image configuration is unavailable.",
        details: { imageRequested: err.image !== undefined },
        phase: "create",
        retryable: true,
      });
    }
    throw err;
  }

  let entry: BaseVmEntry;
  try {
    const programInput = {
      userId: input.user.id,
      billingCustomerType: entitlements.billingCustomerType,
      billingTeamId: entitlements.billingTeamId,
      billingPlanId: entitlements.planId,
      maxActiveVms: entitlements.maxActiveVms,
      provider,
      image: imageSelection.image,
      imageVersion: imageSelection.imageVersion,
      baseName: parsed.body.name,
      bakedFreestyleSignedAdmin: imageUsesBakedFreestyleSignedAdmin(provider, imageSelection.image),
      timing: input.timing,
    };
    entry = await runVmWorkflow(
      input.operation === "reset"
        ? resetBaseVm({ ...programInput, reason: parsed.body.reason })
        : openBaseVm(programInput),
    );
  } catch (err) {
    const response = baseWorkflowErrorResponse(err, input.operation);
    if (response) return response;
    throw err;
  }

  return jsonResponse({
    id: entry.providerVmId,
    provider: entry.provider,
    image: entry.image,
    imageVersion: entry.imageVersion,
    status: entry.status,
    createdAt: entry.createdAt,
    base: {
      id: entry.baseId,
      name: entry.baseName,
      generation: entry.generation,
      retainedProviderVmId: entry.retainedProviderVmId,
    },
  });
}

function baseWorkflowErrorResponse(err: unknown, operation: BaseOperation): Response | null {
  if (isVmCreateInProgressError(err)) {
    return vmErrorResponse({
      error: "vm_base_create_in_progress",
      status: 409,
      message: "Base is already opening.",
      action: "Wait for the existing Base operation to finish. Retrying is safe and will attach to the same Base.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
      phase: "create",
      retryable: true,
      retryAfterSeconds: 2,
    });
  }
  if (isVmCreateFailedError(err)) {
    return vmErrorResponse({
      error: "vm_base_create_failed",
      status: 500,
      message: "Base could not be opened.",
      action: "Retry Base. If it keeps failing, contact support so we can inspect the retained Base state.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
      phase: "create",
      retryable: true,
    });
  }
  if (isVmLimitExceededError(err)) {
    return vmErrorResponse({
      error: "vm_active_limit_exceeded",
      status: 402,
      message: `This plan allows ${err.limit} active Cloud VM${err.limit === 1 ? "" : "s"} at a time.`,
      action: operation === "reset"
        ? "Stop or delete another active Cloud VM, then retry Base reset. The current Base is still retained."
        : "Stop or delete another active Cloud VM, then retry opening Base.",
      extra: { limit: err.limit },
      details: { limit: err.limit },
      phase: "create",
    });
  }
  if (isVmCreateCreditsInsufficientError(err)) {
    return vmErrorResponse({
      error: "vm_create_credits_insufficient",
      status: 402,
      message: "This team has no Cloud VM create credits left.",
      action: operation === "reset"
        ? "Upgrade the team's plan or ask an admin for more create credits before resetting Base. The current Base is unchanged."
        : "Upgrade the team's plan or ask an admin for more create credits, then retry.",
      extra: { amount: err.amount },
      details: { amount: err.amount },
      phase: "billing",
    });
  }
  return vmWorkflowErrorResponse(err);
}

async function parseBaseRequest(
  request: Request,
  operation: BaseOperation,
): Promise<
  | { readonly ok: true; readonly body: { readonly name?: string; readonly image?: string; readonly provider?: ProviderId; readonly billingTeamId?: string; readonly reason?: string | null } }
  | { readonly ok: false; readonly response: Response }
> {
  let raw: unknown = {};
  const rawText = await request.text();
  if (rawText.length > 0) {
    try {
      raw = JSON.parse(rawText) as unknown;
    } catch {
      return {
        ok: false,
        response: vmErrorResponse({
          error: "vm_json_parse_failed",
          status: 400,
          message: `Cloud VM Base ${operation} expected valid JSON.`,
          action: "Send `{}` or omit the body.",
          details: { operation },
        }),
      };
    }
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_expected_object",
        status: 400,
        message: `Cloud VM Base ${operation} expected a JSON object body.`,
        action: "Send `{}` or omit the body.",
        details: { operation },
      }),
    };
  }
  const candidate = raw as Record<string, unknown>;
  const bodyBillingTeamId = candidate.billingTeamId ?? candidate.teamId;
  for (const [field, value] of Object.entries({
    name: candidate.name,
    image: candidate.image,
    provider: candidate.provider,
    billingTeamId: bodyBillingTeamId,
    reason: candidate.reason,
  })) {
    if (value !== undefined && value !== null && typeof value !== "string") {
      return {
        ok: false,
        response: vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: `\`${field}\` must be a string when provided.`,
          action: "Remove the invalid field and retry.",
          details: { field },
        }),
      };
    }
  }
  const provider = typeof candidate.provider === "string" ? candidate.provider.trim() : undefined;
  if (provider && provider !== "e2b" && provider !== "freestyle" && provider !== "daytona") {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_invalid_provider",
        status: 400,
        message: "Unsupported Cloud VM service override.",
        action: "Remove the override to use the default Cloud VM service.",
        details: { field: "provider" },
      }),
    };
  }
  return {
    ok: true,
    body: {
      name: stringValue(candidate.name),
      image: stringValue(candidate.image),
      provider: provider as ProviderId | undefined,
      billingTeamId: stringValue(bodyBillingTeamId),
      reason: stringValue(candidate.reason) ?? null,
    },
  };
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
