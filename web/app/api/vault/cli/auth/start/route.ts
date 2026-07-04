import { createHash, randomBytes, randomInt } from "node:crypto";
import { cloudDb } from "../../../../../../db/client";
import { vaultCliAuthRequests } from "../../../../../../db/schema";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const EXPIRES_IN_SECONDS = 15 * 60;
const INTERVAL_SECONDS = 3;

export async function POST(request: Request): Promise<Response> {
  const body = await readVaultJsonObject(request);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const deviceCode = randomBytes(32).toString("hex");
  const deviceCodeHash = hashDeviceCode(deviceCode);
  const userCode = randomUserCode();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + EXPIRES_IN_SECONDS * 1000);

  await cloudDb().insert(vaultCliAuthRequests).values({
    deviceCodeHash,
    userCode,
    status: "pending",
    createdAt: now,
    expiresAt,
  });

  const verification = new URL("/vault/cli-auth", request.url);
  verification.searchParams.set("code", userCode);

  return jsonResponse({
    deviceCode,
    userCode,
    verificationUrl: verification.toString(),
    expiresInSeconds: EXPIRES_IN_SECONDS,
    intervalSeconds: INTERVAL_SECONDS,
  });
}

function hashDeviceCode(deviceCode: string): string {
  return createHash("sha256").update(deviceCode).digest("hex");
}

function randomUserCode(): string {
  let code = "";
  for (let i = 0; i < 8; i++) {
    code += USER_CODE_ALPHABET[randomInt(USER_CODE_ALPHABET.length)];
  }
  return code;
}
