import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { listVmSessions, openVmSession } from "../../../../../services/vms/workflows";
import type { CloudVmSessionRow } from "../../../../../services/vms/repository";
import {
  optionalClientIdentifier,
  optionalString,
  parseLenientObjectBody,
} from "../../../../../services/vms/routeInput";

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/sessions",
    { "cmux.vm.operation": "list_sessions" },
    "/api/vm/[id]/sessions failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(listVmSessions({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ sessions: run.value.map(sessionPayload) });
    },
  );
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/sessions",
    { "cmux.vm.operation": "open_session" },
    "/api/vm/[id]/sessions failed",
    async ({ user, span }) => {
      const { id } = await params;
      const body = await parseLenientObjectBody(request);
      let sessionId: string | undefined;
      let attachmentId: string | undefined;
      try {
        sessionId = optionalClientIdentifier(body.sessionId ?? body.session_id, "sessionId");
        attachmentId = optionalClientIdentifier(body.attachmentId ?? body.attachment_id, "attachmentId");
      } catch (err) {
        return jsonResponse({
          error: "invalid_request",
          message: err instanceof Error ? err.message : "Invalid Cloud VM session request.",
        }, 400);
      }
      const title = optionalString(body.title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      if (sessionId) setSpanAttributes(span, { "cmux.vm.session.id": sessionId });
      const run = await runVmRoute(openVmSession({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        maxActiveVms: account.entitlements.maxActiveVms,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        sessionId,
        attachmentId,
        title,
      }), { request });
      if (!run.ok) return run.response;
      const result = run.value;
      return jsonResponse({
        endpoint: result.endpoint,
        session: result.session ? sessionPayload(result.session) : null,
      });
    },
  );
}

function sessionPayload(session: CloudVmSessionRow) {
  return {
    id: session.id,
    vmId: session.vmId,
    sessionId: session.providerSessionId,
    title: session.title,
    kind: session.kind,
    status: session.status,
    attachmentCount: session.attachmentCount,
    effectiveCols: session.effectiveCols,
    effectiveRows: session.effectiveRows,
    lastKnownCols: session.lastKnownCols,
    lastKnownRows: session.lastKnownRows,
    scrollbackBytes: session.scrollbackBytes,
    metadata: session.metadata,
    createdAt: session.createdAt.toISOString(),
    updatedAt: session.updatedAt.toISOString(),
    lastAttachedAt: session.lastAttachedAt?.toISOString() ?? null,
    exitedAt: session.exitedAt?.toISOString() ?? null,
    closedAt: session.closedAt?.toISOString() ?? null,
  };
}
