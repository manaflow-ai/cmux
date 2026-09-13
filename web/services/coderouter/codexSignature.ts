import { compactVerify, createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { CodexCredential } from "./types";

const ISSUER = "https://auth.openai.com";
const keys = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`), { timeoutDuration: 5_000 });

export class CodexSignatureError extends Error {
  constructor() { super("Codex credential signature is invalid"); }
}

/** Only a provider-signed, current login may create or replace an account. */
export async function verifyCodexCredential(credential: CodexCredential, key: JWTVerifyGetKey = keys, currentDate?: Date): Promise<void> {
  try {
    await jwtVerify(credential.idToken, key, {
      issuer: ISSUER, audience: "app_EMoamEEZ73f0CkXaXp7hrann", algorithms: ["RS256"],
      requiredClaims: ["exp", "iat", "sub"], clockTolerance: 30, currentDate,
    });
    await jwtVerify(credential.accessToken, key, {
      issuer: ISSUER, audience: "https://api.openai.com/v1", algorithms: ["RS256"],
      requiredClaims: ["exp", "iat", "sub"], clockTolerance: 30, currentDate,
    });
  } catch (error) {
    if (error instanceof errors.JOSEError && error.code !== "ERR_JWKS_TIMEOUT" && error.code !== "ERR_JWKS_INVALID") throw new CodexSignatureError();
    throw error;
  }
}

/** Historical owner proof for encrypted records; this grants no current access. */
export async function verifyStoredCodexCredential(credential: CodexCredential, key: JWTVerifyGetKey = keys): Promise<void> {
  for (const [token, audience] of [[credential.idToken, "app_EMoamEEZ73f0CkXaXp7hrann"], [credential.accessToken, "https://api.openai.com/v1"]]) {
    try {
      const { payload } = await compactVerify(token, key, { algorithms: ["RS256"] });
      const claims = JSON.parse(new TextDecoder().decode(payload));
      const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
      if (claims.iss !== ISSUER || !audiences.includes(audience) || typeof claims.sub !== "string" || !claims.sub) throw new CodexSignatureError();
    } catch (error) {
      if (error instanceof errors.JOSEError || error instanceof SyntaxError) throw new CodexSignatureError();
      throw error;
    }
  }
}
