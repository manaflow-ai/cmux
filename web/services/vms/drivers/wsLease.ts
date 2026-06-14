import { createHash, createPrivateKey, randomBytes, sign, type KeyObject } from "node:crypto";

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function shellArgValue(text: string, argName: string): string | null {
  const escaped = argName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`(?:^|\\s)${escaped}(?:=|\\s+)(?:"([^"]+)"|'([^']+)'|(\\S+))`));
  return match?.[1] ?? match?.[2] ?? match?.[3] ?? null;
}

export function parentDirectory(path: string): string {
  const index = path.lastIndexOf("/");
  return index > 0 ? path.slice(0, index) : ".";
}

export function ensurePrivateDirectoryCommand(filePath: string): string {
  const directory = shellQuote(parentDirectory(filePath));
  return `mkdir -p ${directory} && chmod 700 ${directory}`;
}

export function makeWebSocketLease(
  provider: string,
  label: string,
  singleUse: boolean,
  ttlSeconds: number,
) {
  const token = `cmux-${provider}-${label}-${randomBytes(32).toString("hex")}`;
  const sessionId = randomBytes(16).toString("hex");
  const expiresAtUnix = Math.floor(Date.now() / 1000) + ttlSeconds;
  return {
    token,
    sessionId,
    expiresAtUnix,
    lease: {
      version: 1,
      token_sha256: createHash("sha256").update(token).digest("hex"),
      expires_at_unix: expiresAtUnix,
      session_id: sessionId,
      single_use: singleUse,
    },
  };
}

export type WebSocketLease = ReturnType<typeof makeWebSocketLease>;
export type ReusableRpcLease = Pick<WebSocketLease, "token" | "sessionId" | "expiresAtUnix">;
export type WebSocketAuthToken = Pick<WebSocketLease, "token" | "sessionId" | "expiresAtUnix">;

let cachedSigningKey: { privateKeyPem: string; key: KeyObject } | null = null;

export function makeSignedWebSocketAuthToken(
  kind: "pty" | "rpc",
  audience: string,
  singleUse: boolean,
  ttlSeconds: number,
  privateKeyPem: string,
): WebSocketAuthToken {
  const sessionId = randomBytes(16).toString("hex");
  const expiresAtUnix = Math.floor(Date.now() / 1000) + ttlSeconds;
  const claims = {
    v: 1,
    kind,
    aud: audience,
    sid: sessionId,
    exp: expiresAtUnix,
    single_use: singleUse,
    jti: randomBytes(16).toString("hex"),
  };
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const signature = sign(null, Buffer.from(payload), signingKey(privateKeyPem)).toString("base64url");
  return {
    token: `${payload}.${signature}`,
    sessionId,
    expiresAtUnix,
  };
}

export function leaseClientMetadata(lease: ReusableRpcLease): ReusableRpcLease {
  return {
    token: lease.token,
    sessionId: lease.sessionId,
    expiresAtUnix: lease.expiresAtUnix,
  };
}

export function isReusableRpcLease(value: unknown): value is ReusableRpcLease {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<ReusableRpcLease>;
  return (
    typeof candidate.token === "string" &&
    candidate.token.length > 0 &&
    typeof candidate.sessionId === "string" &&
    candidate.sessionId.length > 0 &&
    typeof candidate.expiresAtUnix === "number" &&
    Number.isFinite(candidate.expiresAtUnix)
  );
}

function normalizedPrivateKeyPem(value: string): string {
  return value.trim().replace(/\\n/g, "\n");
}

function signingKey(privateKeyPem: string): KeyObject {
  const normalized = normalizedPrivateKeyPem(privateKeyPem);
  if (!cachedSigningKey || cachedSigningKey.privateKeyPem !== normalized) {
    cachedSigningKey = {
      privateKeyPem: normalized,
      key: createPrivateKey(normalized),
    };
  }
  return cachedSigningKey.key;
}
