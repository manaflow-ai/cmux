import { signEs256, verifyEs256Jws } from "./crypto";
import type { Env } from "./env";

export const TICKET_TTL_S = 60;
export const REATTACH_TTL_S = 30;
export type Role = "viewer" | "host";
export type Scope = "view" | "full";

export interface TicketPayload {
  sid: string;
  role: Role;
  dev: string;
  peer: string;
  peerKey: string;
  scope: Scope;
  reattach?: boolean;
  iat: number;
  exp: number;
  jti: string;
}

export async function mintTicket(env: Env, claims: Omit<TicketPayload, "iat" | "exp" | "jti">, nowMs = Date.now(), ttlS = TICKET_TTL_S): Promise<string> {
  const iat = Math.floor(nowMs / 1000);
  const payload: TicketPayload = { ...claims, iat, exp: iat + ttlS, jti: crypto.randomUUID() };
  return signEs256(env.TICKET_KEY, payload as unknown as Record<string, unknown>, "dh-ticket");
}

/** Verifies the signature and shape; expiry is the caller's check. */
export async function readTicket(env: Env, token: string): Promise<TicketPayload | null> {
  const p = await verifyEs256Jws(env.TICKET_KEY, token);
  if (!p) return null;
  const ok =
    typeof p.sid === "string" &&
    (p.role === "viewer" || p.role === "host") &&
    typeof p.dev === "string" &&
    typeof p.peer === "string" &&
    typeof p.peerKey === "string" &&
    (p.scope === "view" || p.scope === "full") &&
    (p.reattach === undefined || typeof p.reattach === "boolean") &&
    typeof p.iat === "number" &&
    typeof p.exp === "number" &&
    typeof p.jti === "string";
  return ok ? (p as unknown as TicketPayload) : null;
}
