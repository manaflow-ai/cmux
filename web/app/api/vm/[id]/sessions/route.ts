import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { optionalVmClientIdentifier } from "../../../../../services/vms/requestSchemas";
import {
  listVmSessions,
  openVmSession,
  runVmWorkflow,
} from "../../../../../services/vms/workflows";
import type { CloudVmSessionRow } from "../../../../../services/vms/repository";


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
      try {
        const sessions = await runVmWorkflow(listVmSessions({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
        }));
        return jsonResponse({ sessions: sessions.map(sessionPayload) });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
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
      const body = await parseSessionBody(request);
      const sessionIdResult = optionalVmClientIdentifier(body.sessionId ?? body.session_id, "sessionId");
      if (!sessionIdResult.ok) {
        return jsonResponse({ error: "invalid_request", message: sessionIdResult.message }, 400);
      }
      const attachmentIdResult = optionalVmClientIdentifier(
        body.attachmentId ?? body.attachment_id,
        "attachmentId",
      );
      if (!attachmentIdResult.ok) {
        return jsonResponse({ error: "invalid_request", message: attachmentIdResult.message }, 400);
      }
      const sessionId = sessionIdResult.value;
      const attachmentId = attachmentIdResult.value;
      const title = optionalString(body.title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      if (sessionId) setSpanAttributes(span, { "cmux.vm.session.id": sessionId });
      try {
        const result = await runVmWorkflow(openVmSession({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          sessionId,
          attachmentId,
          title,
        }));
        return jsonResponse({
          endpoint: result.endpoint,
          session: result.session ? sessionPayload(result.session) : null,
        });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

async function parseSessionBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
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
