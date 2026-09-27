import {
  getNonRedirectingStackServerApp,
  isStackConfigured,
} from "../../../lib/stack";
import {
  parseNativeStackTokens,
  unauthorized as unauthorizedResponse,
} from "../../../../services/vms/auth";
import { subrouterErrorResponse } from "../../../../services/subrouter/routeHelpers";


export async function POST(request: Request): Promise<Response> {
  if (!isStackConfigured()) return unauthorizedResponse();

  const tokenStore = parseNativeStackTokens(request);
  if (!tokenStore) return unauthorizedResponse();

  try {
    const app = getNonRedirectingStackServerApp();
    const user = await app.getUser({ tokenStore });
    if (!user) return unauthorizedResponse();

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
