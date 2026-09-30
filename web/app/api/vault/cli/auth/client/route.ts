import { pendingCliAuthClientForUserCode } from "@/services/vault/cliAuth";
import { withAuthedCliAuthApiRoute } from "@/services/vault/routeHelpers";
import { jsonResponse } from "@/services/vms/routeHelpers";

const USER_CODE_RE = /^[A-Z2-9]{8}$/;

/**
 * Which client started a pending device flow, so the approval page can name
 * it. The transaction row is the consent authority: the URL only carries the
 * user code, so a modified link cannot relabel another client as CodeRouter.
 * `"subrouter"` is the persisted legacy protocol ID for CodeRouter.
 */
export async function GET(request: Request): Promise<Response> {
  return withAuthedCliAuthApiRoute(
    request,
    "/api/vault/cli/auth/client",
    { "cmux.vault.operation": "cli_auth.client" },
    "/api/vault/cli/auth/client GET failed",
    {},
    async () => {
      const code = new URL(request.url).searchParams.get("code")?.trim().toUpperCase() ?? "";
      if (!USER_CODE_RE.test(code)) return jsonResponse({ error: "invalid_user_code" }, 400);
      const client = await pendingCliAuthClientForUserCode(code, new Date());
      return jsonResponse({ client }, 200, { "cache-control": "private, no-store" });
    },
  );
}
