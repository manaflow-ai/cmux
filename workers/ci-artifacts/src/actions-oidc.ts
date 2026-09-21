const ISSUER = "https://token.actions.githubusercontent.com";
export const ACTIONS_OIDC_AUDIENCE = "cmux-ci-artifacts";
const JWKS_URL = `${ISSUER}/.well-known/jwks`;
const REPOSITORY = "manaflow-ai/cmux";
const REPOSITORY_ID = "1144115288";
const OWNER_ID = "171392238";
const WORKFLOW_PREFIX = `${REPOSITORY}/.github/workflows/ci.yml@`;
const EVENTS = new Set(["pull_request", "merge_group", "workflow_dispatch"]);
const MAX_TOKEN_LENGTH = 16 * 1024;

type JsonObject = Record<string, unknown>;
export type ActionsIdentity = { runId: string; runAttempt: string; eventName: string };

type KeyCache = { expiresAt: number; keys: Map<string, CryptoKey> };
let keyCache: KeyCache | undefined;
let keyLoading: Promise<KeyCache> | undefined;

function object(value: unknown): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid OIDC document");
  return value as JsonObject;
}

function decode(segment: string): JsonObject {
  if (!/^[A-Za-z0-9_-]+$/.test(segment) || segment.length > MAX_TOKEN_LENGTH) throw new Error("invalid OIDC encoding");
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - segment.length % 4) % 4);
  const raw = atob(padded);
  const bytes = Uint8Array.from(raw, (character) => character.charCodeAt(0));
  return object(JSON.parse(new TextDecoder().decode(bytes)));
}

async function loadKeys(fetcher: typeof fetch, signal?: AbortSignal): Promise<KeyCache> {
  const response = await fetcher(JWKS_URL, {
    headers: { Accept: "application/json", "User-Agent": "cmux-ci-artifacts" },
    redirect: "error",
    signal,
  });
  if (!response.ok) throw new Error("OIDC keys unavailable");
  const document = object(await response.json());
  if (!Array.isArray(document.keys) || document.keys.length < 1 || document.keys.length > 16) {
    throw new Error("invalid OIDC keys");
  }
  const keys = new Map<string, CryptoKey>();
  for (const raw of document.keys) {
    const jwk = object(raw);
    if (jwk.kty !== "RSA" || jwk.use !== "sig" || jwk.alg !== "RS256" || typeof jwk.kid !== "string") continue;
    const imported = await crypto.subtle.importKey(
      "jwk",
      jwk as unknown as JsonWebKey,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    keys.set(jwk.kid, imported);
  }
  if (keys.size === 0) throw new Error("no usable OIDC keys");
  return { expiresAt: Date.now() + 5 * 60_000, keys };
}

async function signingKey(kid: string, fetcher: typeof fetch, signal?: AbortSignal): Promise<CryptoKey> {
  // Tests pass an explicit fetcher and always receive a fresh fixture keyset.
  if (fetcher !== fetch) {
    const loaded = await loadKeys(fetcher, signal);
    const key = loaded.keys.get(kid);
    if (!key) throw new Error("unknown OIDC key");
    return key;
  }

  if (keyCache && keyCache.expiresAt > Date.now()) {
    const cached = keyCache.keys.get(kid);
    if (cached) return cached;
  }
  keyLoading ??= loadKeys(fetcher, signal).finally(() => { keyLoading = undefined; });
  keyCache = await keyLoading;
  const key = keyCache.keys.get(kid);
  if (!key) {
    // A new GitHub signing key may appear before the five-minute cache expires.
    keyCache = await loadKeys(fetcher, signal);
    const refreshed = keyCache.keys.get(kid);
    if (refreshed) return refreshed;
    throw new Error("unknown OIDC key");
  }
  return key;
}

function decimal(value: unknown): string {
  const text = String(value ?? "");
  if (!/^[1-9][0-9]{0,19}$/.test(text)) throw new Error("invalid OIDC run identity");
  return text;
}

function audienceIncludes(value: unknown): boolean {
  if (value === ACTIONS_OIDC_AUDIENCE) return true;
  return Array.isArray(value) && value.includes(ACTIONS_OIDC_AUDIENCE);
}

export async function authenticateActionsRequest(
  request: Request,
  fetcher: typeof fetch = fetch,
  now: number = Date.now(),
  signal?: AbortSignal,
): Promise<ActionsIdentity> {
  const authorization = request.headers.get("Authorization") || "";
  const match = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(authorization);
  if (!match || match[1].length > MAX_TOKEN_LENGTH) throw new Error("missing Actions identity");

  const [encodedHeader, encodedPayload, encodedSignature] = match[1].split(".");
  const header = decode(encodedHeader);
  const claims = decode(encodedPayload);
  if (header.alg !== "RS256" || header.typ !== "JWT" || typeof header.kid !== "string") {
    throw new Error("invalid OIDC header");
  }

  const key = await signingKey(header.kid, fetcher, signal);
  const signatureRaw = atob(encodedSignature.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - encodedSignature.length % 4) % 4));
  const signature = Uint8Array.from(signatureRaw, (character) => character.charCodeAt(0));
  const signed = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
  if (!await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed)) {
    throw new Error("invalid OIDC signature");
  }

  const seconds = Math.floor(now / 1000);
  if (claims.iss !== ISSUER || !audienceIncludes(claims.aud)
      || claims.repository !== REPOSITORY || String(claims.repository_id ?? "") !== REPOSITORY_ID
      || String(claims.repository_owner_id ?? "") !== OWNER_ID || claims.repository_visibility !== "public"
      || typeof claims.workflow_ref !== "string" || !claims.workflow_ref.startsWith(WORKFLOW_PREFIX)
      || typeof claims.event_name !== "string" || !EVENTS.has(claims.event_name)
      || typeof claims.exp !== "number" || claims.exp <= seconds - 30
      || typeof claims.nbf !== "number" || claims.nbf > seconds + 30
      || typeof claims.iat !== "number" || claims.iat > seconds + 30 || claims.iat < seconds - 600) {
    throw new Error("untrusted Actions identity");
  }
  return {
    runId: decimal(claims.run_id),
    runAttempt: decimal(claims.run_attempt),
    eventName: claims.event_name,
  };
}
