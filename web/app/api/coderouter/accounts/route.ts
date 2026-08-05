import { addAccount, parseCredential } from "../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import { accountsWithUsage } from "../../../../services/coderouter/usage";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 128 * 1_024;

export async function GET(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "use-or-manage");
  if (!resolved.ok) return resolved.response;
  const accounts = await accountsWithUsage(resolved.value.team.teamId);
  return Response.json(
    { teamId: resolved.value.team.teamId, accounts },
    { headers: { "cache-control": "no-store" } },
  );
}

export async function POST(request: Request): Promise<Response> {
  const resolved = await resolveCodeRouterRequestContext(request, "manage");
  if (!resolved.ok) return resolved.response;
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_BODY_BYTES) {
    return Response.json({ error: "payload_too_large" }, { status: 413 });
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const credential = parseCredential(value);
  if (!credential) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  const result = await addAccount(resolved.value.team.teamId, credential);
  return Response.json(result, {
    status: result.alreadyExists ? 200 : 201,
    headers: { "cache-control": "no-store" },
  });
}
