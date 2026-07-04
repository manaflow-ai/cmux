import { createHash } from "node:crypto";
import { claimCliAuthTokens, drizzleCliAuthRepository } from "../../../../../../services/vault/cliAuth";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const body = await readVaultJsonObject(request);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const deviceCode = typeof body.value.deviceCode === "string" ? body.value.deviceCode.trim() : "";
  if (!/^[a-f0-9]{64}$/i.test(deviceCode)) {
    return jsonResponse({ status: "expired" });
  }

  const deviceCodeHash = createHash("sha256").update(deviceCode).digest("hex");
  const result = await claimCliAuthTokens(drizzleCliAuthRepository(), deviceCodeHash, new Date());

  return jsonResponse(result);
}
