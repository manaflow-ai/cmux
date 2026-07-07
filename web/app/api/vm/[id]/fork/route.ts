import { unauthorized, verifyRequest, type AuthedUser } from "../../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  requestedVmTeamIdFromRequest,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import {
  isVmCreateCreditsInsufficientError,
  isVmCreateFailedError,
  isVmCreateInProgressError,
  isVmLimitExceededError,
  isVmNotFoundError,
} from "../../../../../services/vms/errors";
import {
  isVmBillingTeamResolutionError,
  resolveVmEntitlements,
} from "../../../../../services/vms/entitlements";
import { enforceVmProGate } from "../../../../../services/vms/proGate";
import { forkVm, runVmWorkflow } from "../../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../../services/vms/timings";

export const dynamic = "force-dynamic";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/fork",
    { "cmux.vm.operation": "fork" },
    "/api/vm/[id]/fork POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "fork", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      const parsedBody = await optionalObjectBody(request);
      if (!parsedBody.ok) return parsedBody.response;
      const body = parsedBody.body;
      const { id } = await params;
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
      const proGateResponse = await enforceVmProGate({ entitlements, userId: user.id });
      if (proGateResponse) return proGateResponse;
      const idempotencyKey = idempotencyKeyFromRequest(request);
      const name = stringField(body, "name");
      setSpanAttributes(span, {
        "cmux.vm.id": id,
        "cmux.billing.team_id_set": !!entitlements.billingTeamId,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });
      try {
        const result = await runVmWorkflow(forkVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          providerVmId: id,
          name,
          idempotencyKey,
          timing,
        }));
        return jsonResponse({
          snapshotId: result.snapshot?.id ?? null,
          id: result.fork.providerVmId,
          provider: result.fork.provider,
          image: result.fork.image,
          imageVersion: result.fork.imageVersion,
          status: result.fork.status,
          createdAt: result.fork.createdAt,
        });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        const response = createLikeErrorResponse(err);
        if (response) return response;
        throw err;
      }
    },
  );
}

type ParsedObjectBody = { ok: true; body: Record<string, unknown> } | { ok: false; response: Response };

async function optionalObjectBody(request: Request): Promise<ParsedObjectBody> {
  const raw = await request.text();
  if (!raw.trim()) return { ok: true, body: {} };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_json_parse_failed",
        status: 400,
        message: "Cloud VM fork expected valid JSON.",
        action: "Send `{}` or `{ \"name\": \"before-agent\" }`.",
      }),
    };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "vm_expected_object",
        status: 400,
        message: "Cloud VM fork expected a JSON object body.",
        action: "Send `{}` or `{ \"name\": \"before-agent\" }`.",
      }),
    };
  }
  return { ok: true, body: parsed as Record<string, unknown> };
}

function stringField(body: Record<string, unknown>, key: string): string | undefined {
  const value = body[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
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
      action: "Wait for the first fork to finish, then retry the same command.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
    });
  }
  if (isVmCreateFailedError(err)) {
    return vmErrorResponse({
      error: "vm_create_failed",
      status: 500,
      message: "The Cloud VM fork create attempt failed.",
      action: "Retry with a fresh fork. If it fails again, copy the details and contact support.",
      details: { idempotencyKeySet: !!err.idempotencyKey },
    });
  }
  if (isVmLimitExceededError(err)) {
    return vmErrorResponse({
      error: "vm_active_limit_exceeded",
      status: 402,
      message: `This plan allows ${err.limit} active Cloud VM${err.limit === 1 ? "" : "s"} at a time.`,
      action: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before forking another.",
      extra: { limit: err.limit },
      details: { limit: err.limit },
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
