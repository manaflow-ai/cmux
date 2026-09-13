import { createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { CodexCredential } from "./types";

const ISSUER = "https://auth.openai.com";
const keys = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`), { timeoutDuration: 5_000 });

export class CodexSignatureError extends Error {
  constructor() { super("Codex credential signature is invalid"); }
}

/** Only a provider-signed, current login may create or replace an account. */
export async function verifyCodexCredential(credential: CodexCredential, key: JWTVerifyGetKey = keys): Promise<void> {
  try {
    await jwtVerify(credential.idToken, key, {
      issuer: ISSUER, audience: "app_EMoamEEZ73f0CkXaXp7hrann", algorithms: ["RS256"],
      requiredClaims: ["exp", "iat", "sub"], clockTolerance: 30,
    });
    await jwtVerify(credential.accessToken, key, {
      issuer: ISSUER, audience: "https://api.openai.com/v1", algorithms: ["RS256"],
      requiredClaims: ["exp", "iat", "sub"], clockTolerance: 30,
    });
  } catch (error) {
    if (error instanceof errors.JOSEError && error.code !== "ERR_JWKS_TIMEOUT" && error.code !== "ERR_JWKS_INVALID") throw new CodexSignatureError();
    throw error;
  }
}
