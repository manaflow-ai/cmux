import {
  getNonRedirectingStackServerApp,
  isStackConfigured,
} from "../../../lib/stack";
import {
  parseNativeStackTokens,
  unauthorized,
} from "../../../../services/vms/auth";
import { subrouterErrorResponse } from "../../../../services/subrouter/routeHelpers";


export async function POST(request: Request): Promise<Response> {
  if (!isStackConfigured()) return unauthorized();

  const tokenStore = parseNativeStackTokens(request);
  if (!tokenStore) return unauthorized();

  try {
    const app = getNonRedirectingStackServerApp();
    const user = await app.getUser({ tokenStore });
    if (!user) return unauthorized();

    await app.signOut({ tokenStore });
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-type": "application/json",
      },
    });
  } catch (error) {
    return subrouterErrorResponse(error);
  }
}
