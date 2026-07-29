import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { unauthorized } from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  if (!isStackConfigured()) return unauthorized();

  const authorization = request.headers.get("authorization");
  const refreshToken = request.headers.get("x-stack-refresh-token")?.trim();
  if (!authorization?.toLowerCase().startsWith("bearer ") || !refreshToken) {
    return unauthorized();
  }
  const accessToken = authorization.slice("bearer ".length).trim();
  if (!accessToken) return unauthorized();

  const user = await getStackServerApp().getUser({
    tokenStore: { accessToken, refreshToken },
  });
  if (!user) return unauthorized();

  await user.signOut();
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
  });
}
