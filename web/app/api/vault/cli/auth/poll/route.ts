import { createHash } from "node:crypto";
import {
  claimCliAuthTokens,
  drizzleCliAuthRepository,
  type CliAuthTokens,
} from "../../../../../../services/vault/cliAuth";
import { withVaultApiRoute } from "../../../../../../services/vault/routeHelpers";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import { getStackServerApp } from "../../../../../lib/stack";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SESSION_EXPIRES_IN_MS = 90 * 24 * 60 * 60 * 1000;

// Tokens are minted here, at claim time, for the user recorded at approval.
// Nothing token-shaped is ever written to the database, and a duplicate
// approve can no longer mint an orphaned session.
async function mintStackTokens(userId: string): Promise<CliAuthTokens | null> {
  const user = await getStackServerApp().getUser(userId);
  if (!user) return null;
  const session = await user.createSession({ expiresInMillis: SESSION_EXPIRES_IN_MS });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) return null;
  return { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken };
}

export async function POST(request: Request): Promise<Response> {
  return withVaultApiRoute(
    request,
    "/api/vault/cli/auth/poll",
    { "cmux.vault.operation": "cli_auth.poll" },
    "/api/vault/cli/auth/poll POST failed",
    async ({ span }) => {
      const body = await readVaultJsonObject(request);
      if (!body.ok) {
        return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
      }
      const deviceCode = typeof body.value.deviceCode === "string" ? body.value.deviceCode.trim() : "";
      if (!/^[a-f0-9]{64}$/i.test(deviceCode)) {
        setSpanAttributes(span, {
          "cmux.vault.cli_auth.device_code_valid": false,
          "cmux.vault.cli_auth.result_status": "expired",
        });
        return jsonResponse({ status: "expired" });
      }
      setSpanAttributes(span, { "cmux.vault.cli_auth.device_code_valid": true });

      const deviceCodeHash = createHash("sha256").update(deviceCode).digest("hex");
      const result = await claimCliAuthTokens(
        drizzleCliAuthRepository(),
        mintStackTokens,
        deviceCodeHash,
        new Date(),
      );
      setSpanAttributes(span, { "cmux.vault.cli_auth.result_status": result.status });

      return jsonResponse(result);
    },
  );
}
