import { unauthorized, verifyRequest, type AuthedUser } from "../../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  requestedVmTeamIdFromRequest,
  vmCreateWorkflowErrorResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
  vmRequiresProResponse,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { vmOptionalTrimmedString } from "../../../../../services/vms/requestSchemas";
import {
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  resolveVmEntitlements,
} from "../../../../../services/vms/entitlements";
import { forkVm, runVmWorkflow } from "../../../../../services/vms/workflows";
import { VmTimingRecorder } from "../../../../../services/vms/timings";
import { authProviderErrorResponse } from "../../../../../services/vms/authErrors";


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
      const requestedBillingTeamId = vmOptionalTrimmedString(body.billingTeamId) ??
        vmOptionalTrimmedString(body.teamId) ??
        requestedVmTeamIdFromRequest(request);
      if (requestedBillingTeamId && !user.teamIds.includes(requestedBillingTeamId)) {
        let refreshedUser: AuthedUser | null;
        try {
          refreshedUser = await verifyRequest(request, { requestedTeamId: requestedBillingTeamId });
        } catch (error) {
          return authProviderErrorResponse(error, "/api/vm.fork.team-auth");
        }
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
      const name = vmOptionalTrimmedString(body.name);
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
          teamIds: user.teamIds,
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
        const response = createLikeErrorResponse(err, entitlements.planId);
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

function idempotencyKeyFromRequest(request: Request): string | undefined {
  const raw = (request.headers.get("idempotency-key") || request.headers.get("x-cmux-idempotency-key") || "").trim();
  return raw ? raw.slice(0, 128) : undefined;
}

function createLikeErrorResponse(err: unknown, planId: string): Response | null {
  return vmCreateWorkflowErrorResponse(err, {
    planId,
    limitRetryAction: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before forking another.",
    inProgress: {
      action: "Wait for the first fork to finish, then retry the same command.",
    },
    failed: {
      message: "The Cloud VM fork create attempt failed.",
      action: "Retry with a fresh fork. If it fails again, copy the details and contact support.",
    },
  });
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
