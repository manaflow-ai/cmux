import { createHash, randomBytes } from "node:crypto";

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
