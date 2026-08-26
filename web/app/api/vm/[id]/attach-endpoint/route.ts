import {
  jsonResponse,
  notFoundVm,
  vmFreeAccessExpiredResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmFreeAccessExpiredError, isVmNotFoundError } from "../../../../../services/vms/errors";
import { openAttachEndpoint, openVmCmuxRemote, runVmWorkflow } from "../../../../../services/vms/workflows";


export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/attach-endpoint",
    { "cmux.vm.operation": "open_attach" },
    "/api/vm/[id]/attach-endpoint failed",
    async ({ user, span }) => {
      const { id } = await params;
      const body = await parseAttachBody(request);
      const requireDaemon = body.requireDaemon === true || body.require_daemon === true;
      let sessionId: string | undefined;
      let attachmentId: string | undefined;
      try {
        sessionId = optionalClientIdentifier(body.sessionId ?? body.session_id, "sessionId");
        attachmentId = optionalClientIdentifier(body.attachmentId ?? body.attachment_id, "attachmentId");
      } catch (err) {
        return jsonResponse({
          error: "invalid_request",
          message: err instanceof Error ? err.message : "Invalid Cloud VM attach request.",
        }, 400);
      }
      const sessionTitle = optionalString(body.title ?? body.sessionTitle ?? body.session_title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      // Opt-in transport: the cmux-tui remote daemon (Phase 1 of the cmuxd-remote
      // migration). Clients that do not ask keep the WebSocket PTY/RPC endpoint.
      const transport = optionalString(body.transport);
      if (transport === "cmux-remote") {
        let deviceFingerprint: string | undefined;
        try {
          deviceFingerprint = optionalClientIdentifier(body.deviceFingerprint ?? body.device_fingerprint, "deviceFingerprint");
        } catch (err) {
          return jsonResponse({
            error: "invalid_request",
            message: err instanceof Error ? err.message : "Invalid Cloud VM attach request.",
          }, 400);
        }
        setSpanAttributes(span, { "cmux.vm.attach.transport": "cmux-remote" });
        try {
          const endpoint = await runVmWorkflow(openVmCmuxRemote({
            userId: user.id,
            billingTeamId: account.entitlements.billingTeamId,
            teamIds: user.teamIds,
            providerVmId: id,
            deviceFingerprint,
          }));
          return jsonResponse(endpoint);
        } catch (err) {
          if (isVmNotFoundError(err)) return notFoundVm(id);
          throw err;
        }
      }
      if (transport && transport !== "websocket") {
        return jsonResponse({
          error: "invalid_request",
          message: `Unknown attach transport "${transport}". Use "websocket" or "cmux-remote".`,
        }, 400);
      }
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      if (sessionId) setSpanAttributes(span, { "cmux.vm.attach.session_id": sessionId });
      try {
        const endpoint = await runVmWorkflow(openAttachEndpoint({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          callerPlanId: account.entitlements.planId,
          teamIds: user.teamIds,
          providerVmId: id,
          sessionTitle,
          options: { requireDaemon, sessionId, attachmentId },
        }));
        setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isVmFreeAccessExpiredError(err)) {
          return vmFreeAccessExpiredResponse({ vmId: id, windowDays: err.windowDays });
        }
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function optionalClientIdentifier(value: unknown, fieldName: string): string | undefined {
  const trimmed = optionalString(value);
  if (!trimmed) return undefined;
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(trimmed)) {
    throw new Error(`${fieldName} must be 1-128 characters of letters, numbers, dot, underscore, colon, or dash`);
  }
  return trimmed;
}

async function parseAttachBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
