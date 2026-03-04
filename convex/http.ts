import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";

const http = httpRouter();

// TODO(auth): Placeholder auth. The Bearer token is treated as the userId directly.
// Before shipping, replace with real API key validation against an `apiKeys` table
// or Stack Auth JWT verification. Anyone who knows a userId can impersonate them.
function extractUserId(request: Request): string | null {
  const auth = request.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  const token = auth.slice(7).trim();
  if (!token) return null;
  return token;
}

function unauthorized() {
  return new Response(JSON.stringify({ error: "Unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}

function badRequest(message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status: 400,
    headers: { "Content-Type": "application/json" },
  });
}

function ok(data: unknown = { ok: true }) {
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

http.route({
  path: "/api/terminal/register",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const userId = extractUserId(request);
    if (!userId) return unauthorized();

    let body: any;
    try { body = await request.json(); } catch { return badRequest("Invalid JSON"); }
    if (!body.deviceId || typeof body.deviceId !== "string") return badRequest("deviceId required");
    if (!body.hostname || typeof body.hostname !== "string") return badRequest("hostname required");
    const id = await ctx.runMutation(api.terminalDevices.register, {
      userId,
      deviceId: body.deviceId,
      hostname: body.hostname,
      tailscaleHostname: body.tailscaleHostname,
      sshPort: body.sshPort ?? 22,
      capabilities: body.capabilities ?? ["cmux"],
      osVersion: body.osVersion ?? "unknown",
      appVersion: body.appVersion ?? "unknown",
    });

    return ok({ id });
  }),
});

http.route({
  path: "/api/terminal/heartbeat",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const userId = extractUserId(request);
    if (!userId) return unauthorized();

    let body: any;
    try { body = await request.json(); } catch { return badRequest("Invalid JSON"); }
    if (!body.deviceId || typeof body.deviceId !== "string") return badRequest("deviceId required");

    await ctx.runMutation(api.terminalDevices.heartbeat, {
      userId,
      deviceId: body.deviceId,
    });

    return ok();
  }),
});

http.route({
  path: "/api/terminal/event",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const userId = extractUserId(request);
    if (!userId) return unauthorized();

    let body: any;
    try { body = await request.json(); } catch { return badRequest("Invalid JSON"); }
    if (!body.deviceId || typeof body.deviceId !== "string") return badRequest("deviceId required");
    if (!body.type || typeof body.type !== "string") return badRequest("type required");
    if (!body.title || typeof body.title !== "string") return badRequest("title required");
    const id = await ctx.runMutation(api.terminalEvents.create, {
      userId,
      deviceId: body.deviceId,
      type: body.type,
      title: body.title,
      body: body.body,
      workspaceId: body.workspaceId,
      metadata: body.metadata,
    });

    return ok({ id });
  }),
});

http.route({
  path: "/api/terminal/workspaces",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const userId = extractUserId(request);
    if (!userId) return unauthorized();

    let body: any;
    try { body = await request.json(); } catch { return badRequest("Invalid JSON"); }
    if (!body.deviceId || typeof body.deviceId !== "string") return badRequest("deviceId required");
    if (!Array.isArray(body.workspaces)) return badRequest("workspaces array required");
    const id = await ctx.runMutation(api.terminalWorkspaceSnapshots.update, {
      userId,
      deviceId: body.deviceId,
      workspaces: body.workspaces,
    });

    return ok({ id });
  }),
});

export default http;
