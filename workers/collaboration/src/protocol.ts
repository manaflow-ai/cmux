export interface PeerInfo {
  peerID: string;
  displayName: string;
  color: string;
}

export interface RelayEnvelope {
  type: string;
  [key: string]: unknown;
}

export interface SessionCreateResponse {
  sessionID: string;
  sessionCode: string;
  token: string;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function parsePeer(value: unknown): PeerInfo | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  if (typeof record.peerID !== "string" || record.peerID.trim() === "") return null;
  if (typeof record.displayName !== "string" || record.displayName.trim() === "") return null;
  if (typeof record.color !== "string" || record.color.trim() === "") return null;
  return {
    peerID: record.peerID,
    displayName: record.displayName,
    color: record.color,
  };
}

export function parseEnvelope(message: string | ArrayBuffer): RelayEnvelope | null {
  const text = typeof message === "string" ? message : new TextDecoder().decode(message);
  if (text.length > 1024 * 1024) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const record = parsed as Record<string, unknown>;
  return typeof record.type === "string" ? (record as RelayEnvelope) : null;
}

export function randomToken(bytes = 18): string {
  const values = new Uint8Array(bytes);
  crypto.getRandomValues(values);
  return [...values].map((value) => value.toString(16).padStart(2, "0")).join("");
}

export function randomSessionCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const values = new Uint8Array(8);
  crypto.getRandomValues(values);
  const chars = [...values].map((value) => alphabet[value % alphabet.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4).join("")}`;
}
