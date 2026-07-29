import {
  getNonRedirectingStackServerApp,
  isStackConfigured,
} from "../../../lib/stack";
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

  const tokenStore = { accessToken, refreshToken };
  const app = getNonRedirectingStackServerApp();
  const user = await app.getUser({
    tokenStore,
  });
  if (!user) return unauthorized();

  await app.signOut({
    tokenStore: { accessToken, refreshToken },
  });
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
  });
}
