import { z } from "zod";
import { env } from "../../../env";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  requireVmPrincipal,
  vmPrincipalFailureResponse,
} from "../../../../services/vms/vmPrincipal";

const identifier = z.string().min(1).max(256);
const workspaceRow = z.strictObject({
  id: identifier,
  name: z.string().max(512),
  index: z.number().int().nonnegative().safe(),
  focused: z.boolean(),
});
const terminalRow = z.strictObject({
  id: identifier,
  title: z.string().max(512),
  workspaceId: identifier.nullable(),
  cwd: z.string().max(4096).nullable(),
  agent: z.string().max(128).nullable(),
});
const requestBody = z.strictObject({
  vmId: identifier.optional(),
  generation: identifier,
  revision: z.number().int().nonnegative().safe(),
  snapshot: z.strictObject({
    workspaces: z.array(workspaceRow).max(4096),
    terminals: z.array(terminalRow).max(16384),
  }),
});

const JSON_HEADERS = { "cache-control": "no-store", "content-type": "application/json" } as const;

/** VM-authenticated bridge into the Worker-owned team Durable Object. */
export async function POST(request: Request): Promise<Response> {
  const auth = await requireVmPrincipal(request);
  if (!auth.ok) return vmPrincipalFailureResponse(auth.reason);
  const body = await readBoundedJsonObject(request, 4 * 1024 * 1024);
  if (!body.ok) return response(body.error === "request_too_large" ? 413 : 400, body.error);
  const parsed = requestBody.safeParse(body.value);
  if (!parsed.success) return response(400, "invalid_workspace_snapshot");
  if (parsed.data.vmId && parsed.data.vmId !== auth.principal.vm.id) return response(403, "vm_mismatch");
  if (!env.CMUX_IROH_V2_ORIGIN || !env.CMUX_IROH_V2_PUBLISHER_SECRET) {
    return response(503, "workspace_publisher_unavailable");
  }

  try {
    const upstream = await fetch(new URL("/v2/workspace/publish", env.CMUX_IROH_V2_ORIGIN), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-cmux-workspace-publisher-secret": env.CMUX_IROH_V2_PUBLISHER_SECRET,
      },
      body: JSON.stringify({ ...parsed.data, vmId: auth.principal.vm.id, teamId: auth.principal.teamId, source: "vm" }),
      signal: AbortSignal.timeout(10_000),
    });
    const text = await upstream.text();
    return new Response(text, { status: upstream.status, headers: JSON_HEADERS });
  } catch {
    return response(503, "workspace_publisher_unavailable");
  }
}

function response(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), { status, headers: JSON_HEADERS });
}
