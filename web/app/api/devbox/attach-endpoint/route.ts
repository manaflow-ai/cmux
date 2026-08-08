// Mint a WebSocket PTY attach lease for the caller's devbox. The underlying
// workflow auto-resumes a paused devbox before minting, so attach transparently
// wakes the VM. The default shell inside a devbox sandbox is the cmux TUI.

import {
  isDevboxNotFoundError,
  openDevboxAttach,
  runDevboxWorkflow,
} from "../../../../services/vms/devbox";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import { devboxNotFoundResponse } from "../shared";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/devbox/attach-endpoint",
    { "cmux.vm.operation": "devbox_open_attach" },
    "/api/devbox/attach-endpoint POST failed",
    async ({ user, span }) => {
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
          message: err instanceof Error ? err.message : "Invalid devbox attach request.",
        }, 400);
      }
      const sessionTitle = optionalString(body.title ?? body.sessionTitle ?? body.session_title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      try {
        const endpoint = await runDevboxWorkflow(openDevboxAttach({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          sessionTitle,
          options: { requireDaemon, sessionId, attachmentId },
        }));
        setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isDevboxNotFoundError(err)) return devboxNotFoundResponse();
        throw err;
      }
    },
  );
}

async function parseAttachBody(request: Request): Promise<Record<string, unknown>> {
  const raw = await request.text();
  if (!raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return parsed as Record<string, unknown>;
  } catch {
    return {};
  }
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
