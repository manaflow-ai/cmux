import { unauthorized, verifyRequest, type AuthedUser } from "../../../../services/vms/auth";
import { defaultProviderId, type ProviderId } from "../../../../services/vms/drivers";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmErrorResponse,
  withAuthedVmApiRoute,
  vmRequiresProResponse,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import {
  isVmCreateCreditsInsufficientError,
  isVmCreateFailedError,
  isVmCreateInProgressError,
  isVmLimitExceededError,
  isVmSnapshotNotFoundError,
} from "../../../../services/vms/errors";
import {
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../../../../services/vms/entitlements";
import { restoreVm, runVmWorkflow } from "../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../services/vms/timings";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/restore",
    { "cmux.vm.operation": "restore" },
    "/api/vm/restore POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "restore", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      const parsedBody = await requiredObjectBody(request);
      if (!parsedBody.ok) return parsedBody.response;
      const body = parsedBody.body;
      if (body === null) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "Cloud VM restore expected a JSON object body.",
          action: "Send `{ \"snapshotId\": \"...\" }`.",
        });
      }
      const snapshotId = stringField(body, "snapshotId") ?? stringField(body, "snapshot_id");
      if (!snapshotId) {
        return vmErrorResponse({
          error: "vm_invalid_request",
          status: 400,
          message: "`snapshotId` is required.",
          action: "Run `cmux vm snapshot <id>` first, then restore the printed snapshot id.",
          details: { field: "snapshotId" },
        });
      }
      const providerResult = providerField(body);
      if (!providerResult.ok) return providerResult.response;
      const provider = providerResult.provider ?? defaultProviderId();
      let user: AuthedUser = initialUser;
      const requestedBillingTeamId = stringField(body, "billingTeamId") ?? stringField(body, "teamId") ?? requestedVmTeamIdFromRequest(request);
      if (requestedBillingTeamId && !user.teamIds.includes(requestedBillingTeamId)) {
        const refreshedUser = await verifyRequest(request, { requestedTeamId: requestedBillingTeamId });
        if (!refreshedUser) return unauthorized();
        user = refreshedUser;
      }
      let entitlements;
      try {
        entitlements = resolveVmEntitlements(user, process.env, {
          requestedBillingTeamId,
          requireTeam: true,
        });
      } catch (err) {
        if (isVmBillingTeamResolutionError(err)) return billingTeamErrorResponse(err);
        throw err;
      }
      if (isVmProGateBlocked(entitlements)) {
        return vmRequiresProResponse();
      }
      const idempotencyKey = idempotencyKeyFromRequest(request);
      setSpanAttributes(span, {
        "cmux.snapshot.id": snapshotId,
        "cmux.vm.provider": provider,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });
      try {
        const restored = await runVmWorkflow(restoreVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          provider,
          snapshotId,
          idempotencyKey,
          timing,
        }));
        return jsonResponse({
          id: restored.providerVmId,
          provider: restored.provider,
          image: restored.image,
          imageVersion: restored.imageVersion,
          status: restored.status,
          createdAt: restored.createdAt,
        });
      } catch (err) {
        const response = createLikeErrorResponse(err);
        if (response) return response;
        throw err;
      }
    },
  );
}

type ParsedObjectBody = { ok: true; body: Record<string, unknown> | null } | { ok: false; response: Response };

async function requiredObjectBody(request: Request): Promise<ParsedObjectBody> {
  const raw = await request.text();
  if (!raw.trim()) return { ok: true, body: null };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_json_parse_failed",
        status: 400,
        message: "Cloud VM restore expected valid JSON.",
        action: "Send `{ \"snapshotId\": \"...\" }`.",
      }),
    };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_expected_object",
        status: 400,
        message: "Cloud VM restore expected a JSON object body.",
        action: "Send `{ \"snapshotId\": \"...\" }`.",
      }),
    };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}

function stringField(body: Record<string, unknown>, key: string): string | undefined {
  const value = body[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

type ProviderFieldResult = { ok: true; provider?: ProviderId } | { ok: false; response: Response };

function providerField(body: Record<string, unknown>): ProviderFieldResult {
  const value = stringField(body, "provider");
  if (!value) return { ok: true };
  if (value === "e2b" || value === "freestyle" || value === "daytona") return { ok: true, provider: value };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Use the default Cloud VM service, or pass a supported provider.",
      details: { field: "provider" },
    }),
  };
}

function idempotencyKeyFromRequest(request: Request): string | undefined {
  const raw = (request.headers.get("idempotency-key") || request.headers.get("x-cmux-idempotency-key") || "").trim();
  return raw ? raw.slice(0, 128) : undefined;
}

function createLikeErrorResponse(err: unknown): Response | null {
  if (isVmCreateInProgressError(err)) {
    return vmErrorResponse({
      error: "vm_create_in_progress",
      status: 409,
      message: "A Cloud VM create is already running for this request.",
      action: "Wait for the first restore to finish, then retry the same command.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
    });
  }
  if (isVmCreateFailedError(err)) {
    return vmErrorResponse({
      error: "vm_create_failed",
      status: 500,
      message: "The Cloud VM restore create attempt failed.",
      action: "Retry with a fresh restore. If it fails again, copy the details and contact support.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
    });
  }
  if (isVmLimitExceededError(err)) {
    return vmErrorResponse({
      error: "vm_active_limit_exceeded",
      status: 402,
      message: `This plan allows ${err.limit} active Cloud VM${err.limit === 1 ? "" : "s"} at a time.`,
      action: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before restoring another.",
      extra: { limit: err.limit },
      details: { limit: err.limit },
    });
  }
  if (isVmSnapshotNotFoundError(err)) {
    return vmErrorResponse({
      error: "vm_snapshot_not_found",
      status: 404,
      message: "Cloud VM snapshot was not found for this account.",
      action: "Create a snapshot from one of this team's Cloud VMs, then retry restore with that snapshot id.",
      details: { snapshotId: err.snapshotId },
    });
  }
  if (isVmCreateCreditsInsufficientError(err)) {
    return vmErrorResponse({
      error: "vm_create_credits_insufficient",
      status: 402,
      message: "This team has no Cloud VM create credits left.",
      action: "Upgrade the team's plan or ask an admin to add Cloud VM create credits, then retry.",
      extra: { amount: err.amount },
      details: { amount: err.amount },
    });
  }
  return null;
}

function billingTeamErrorResponse(err: {
  readonly code: "vm_billing_team_required" | "vm_billing_team_not_found";
  readonly status: number;
  readonly message: string;
}) {
  return vmErrorResponse({
    error: err.code,
    status: err.status,
    message: err.code === "vm_billing_team_not_found" ? "That team is not available for this account." : "cmux needs to know which team should own this Cloud VM.",
    action: err.code === "vm_billing_team_not_found"
      ? "Switch to a team you belong to, or run `cmux auth login` again and retry with the correct team id."
      : "Select a team in cmux, or pass the team id with `X-Cmux-Team-Id`.",
    reason: err.message,
  });
}
