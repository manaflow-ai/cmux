import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmResourceErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { openAttachEndpoint, openVmCmuxRemote, runVmWorkflow } from "../../../../../services/vms/workflows";
import {
  capabilityList,
  optionalClientIdentifier,
  optionalString,
  parseLenientObjectBody,
} from "../../../../../services/vms/routeInput";

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
      const body = await parseLenientObjectBody(request);
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
      // Transport selection: "cmux-remote" is the cmux-tui remote daemon — the only
      // transport Blaxel machines serve. Clients that do not ask keep the legacy
      // WebSocket PTY/RPC endpoint on providers that still run cmuxd-remote; on a
      // cmux-tui-only machine that request answers 409 vm_attach_transport_unsupported.
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
        const clientCapabilities = capabilityList(body.clientCapabilities ?? body.client_capabilities);
        setSpanAttributes(span, { "cmux.vm.attach.transport": "cmux-remote" });
        try {
          const endpoint = await runVmWorkflow(openVmCmuxRemote({
            userId: user.id,
            billingTeamId: account.entitlements.billingTeamId,
            teamIds: user.teamIds,
            providerVmId: id,
            deviceFingerprint,
            clientCapabilities,
            callerPlanId: account.entitlements.planId,
          }));
          return jsonResponse(endpoint);
        } catch (err) {
          const response = vmResourceErrorResponse(err, id);
          if (response) return response;
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
        const response = vmResourceErrorResponse(err, id);
        if (response) return response;
        throw err;
      }
    },
  );
}
