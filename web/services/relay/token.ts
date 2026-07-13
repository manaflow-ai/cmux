import { createPrivateKey, sign as edSign, type KeyObject } from "node:crypto";

export const RELAY_TOKEN_ISS = "cmux";
export const RELAY_TOKEN_AUD = "cmux-relay";
export const RELAY_TOKEN_TTL_SECONDS = 300;

const HEX_ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
const BASE32_ENDPOINT_ID_RE = /^[a-z2-7]{51}[aq]$/;

export function isValidEndpointId(value: string): boolean {
  const normalized = value.toLowerCase();
  return HEX_ENDPOINT_ID_RE.test(normalized) ||
    BASE32_ENDPOINT_ID_RE.test(normalized);
}

let cached: { readonly pem: string; readonly key: KeyObject } | null = null;

export function relaySigningKey(): KeyObject | null {
  const pem = process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM
    ?.replace(/\\n/g, "\n")
    .trim();
  if (!pem) return null;
  if (cached?.pem === pem) return cached.key;
  try {
    const key = createPrivateKey(pem);
    if (key.asymmetricKeyType !== "ed25519") return null;
    cached = { pem, key };
    return key;
  } catch {
    return null;
  }
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

export function mintRelayToken(params: {
  readonly sub: string;
  readonly endpointId: string;
  readonly key: KeyObject;
  readonly nowSeconds: number;
}): { readonly token: string; readonly expiresAt: number } {
  const expiresAt = params.nowSeconds + RELAY_TOKEN_TTL_SECONDS;
  const header = { alg: "EdDSA", typ: "JWT" } as const;
  const payload = {
    iss: RELAY_TOKEN_ISS,
    aud: RELAY_TOKEN_AUD,
    sub: params.sub,
    iat: params.nowSeconds,
    exp: expiresAt,
    endpoint_id: params.endpointId.toLowerCase(),
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(
    JSON.stringify(payload),
  )}`;
  const signature = edSign(null, Buffer.from(signingInput), params.key);
  return {
    token: `${signingInput}.${b64url(signature)}`,
    expiresAt,
  };
}
