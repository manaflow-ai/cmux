import { PersistentWorkspaceError, type PersistentWorkspaceService, type PersistentWorkspaceLookupInput, type PersistentWorkspaceProviderInput } from "./persistentWorkspace";

export function workspaceJson(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}

export function workspaceHttpError(error: unknown): Response {
  if (error instanceof PersistentWorkspaceError) {
    const status = error.code === "workspace_not_found" ? 404 : error.code === "workspace_forbidden" ? 403
      : error.code === "workspace_idempotency_conflict" || error.code === "workspace_invalid_state" ? 409
        : error.code === "workspace_input_invalid" ? 400 : 502;
    return workspaceJson({ error: error.code, message: error.message }, status);
  }
  return workspaceJson({ error: "workspace_unavailable" }, 503);
}
function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
function providerInput(value: unknown): PersistentWorkspaceProviderInput | undefined {
  const body = object(value);
  if (!body) return undefined;
  const terminal = object(body.terminal);
  return {
    ...(typeof body.image === "string" ? { image: body.image } : {}),
    ...(typeof body.imageVersion === "string" ? { imageVersion: body.imageVersion } : {}),
    ...(typeof body.memoryMb === "number" && Number.isSafeInteger(body.memoryMb) ? { memoryMb: body.memoryMb } : {}),
    ...(terminal ? { terminal: {
      ...(terminal.agent === "codex" || terminal.agent === "claude" || terminal.agent === "pi" || terminal.agent === "opencode" ? { agent: terminal.agent } : {}),
      ...(typeof terminal.prompt === "string" ? { prompt: terminal.prompt } : {}),
      ...(typeof terminal.cwd === "string" ? { cwd: terminal.cwd } : {}),
    } } : {}),
  };
}
/** Shared mutation owner for Next route handlers and the isolated staging API. */
export async function workspaceHttp(request: Request, service: PersistentWorkspaceService,
  principal: { ownerId: string; tenantId: string }, runtimeId?: string): Promise<Response> {
  try {
    if (request.method === "GET" && runtimeId) return workspaceJson(await service.get({ ...principal, runtimeId }));
    if (request.method !== "POST") return workspaceJson({ error: "method_not_allowed" }, 405);
    const body = object(await request.json().catch(() => null));
    if (!body) return workspaceJson({ error: "workspace_invalid_request" }, 400);
    if (!runtimeId) {
      const key = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim();
      if (!key) return workspaceJson({ error: "workspace_idempotency_required" }, 400);
      return workspaceJson(await service.create({ ...principal, idempotencyKey: key,
        ...(typeof body.name === "string" ? { workspaceName: body.name } : {}),
        providerInput: providerInput(body.providerInput ?? body),
      }), 201);
    }
    const lookup: PersistentWorkspaceLookupInput = { ...principal, runtimeId };
    switch (body.action) {
      case "attach": case "rotate": return workspaceJson(await service.attach(lookup));
      case "resume": return workspaceJson(await service.resume(lookup));
      case "suspend": return workspaceJson(await service.suspend(lookup));
      case "stop": return workspaceJson(await service.stop(lookup));
      default: return workspaceJson({ error: "workspace_action_invalid" }, 400);
    }
  } catch (error) { return workspaceHttpError(error); }
}
