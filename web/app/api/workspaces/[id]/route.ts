import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import {
  PersistentWorkspaceError,
} from "../../../../services/vms/persistentWorkspace";
import { persistentWorkspaceServiceForRequest } from "../../../../services/vms/freestyleWorkspaceComposition";

function errorResponse(error: unknown): Response {
  if (error instanceof PersistentWorkspaceError) {
    const status = error.code === "workspace_not_found" ? 404
      : error.code === "workspace_forbidden" ? 403
        : error.code === "workspace_invalid_state" ? 409 : 502;
    return jsonResponse({ error: error.code, message: error.message }, status);
  }
  console.error("[workspaces] lifecycle operation failed", error);
  return jsonResponse({ error: "workspace_unavailable", message: "Persistent workspace operation is unavailable." }, 503);
}

type WorkspaceParams = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: WorkspaceParams): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/workspaces/[id]",
    { "cmux.vm.operation": "workspace_get" },
    "/api/workspaces/[id] GET failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const service = await persistentWorkspaceServiceForRequest({ user, entitlements: account.entitlements });
      const { id } = await params;
      try {
        return jsonResponse(await service.get({ runtimeId: id, ownerId: user.id, tenantId: account.entitlements.billingTeamId ?? user.billingTeamId }));
      } catch (error) {
        return errorResponse(error);
      }
    },
  );
}

/** POST with an explicit action keeps lifecycle mutations idempotent at one route. */
export async function POST(request: Request, { params }: WorkspaceParams): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/workspaces/[id]",
    { "cmux.vm.operation": "workspace_lifecycle" },
    "/api/workspaces/[id] POST failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const service = await persistentWorkspaceServiceForRequest({ user, entitlements: account.entitlements });
      const { id } = await params;
      let body: Record<string, unknown> | null = null;
      try {
        const parsed = await request.json();
        body = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
      } catch { /* handled below */ }
      const action = body?.action;
      if (action !== "resume" && action !== "suspend" && action !== "stop" && action !== "attach") {
        return jsonResponse({ error: "workspace_action_invalid", message: "action must be resume, suspend, stop, or attach." }, 400);
      }
      const lookup = { runtimeId: id, ownerId: user.id, tenantId: account.entitlements.billingTeamId ?? user.billingTeamId };
      try {
        if (action === "resume") return jsonResponse(await service.resume(lookup));
        if (action === "suspend") return jsonResponse(await service.suspend(lookup));
        if (action === "stop") return jsonResponse(await service.stop(lookup));
        return jsonResponse(await service.attach(lookup));
      } catch (error) {
        return errorResponse(error);
      }
    },
  );
}

