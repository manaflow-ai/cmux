import { z } from "zod";
import { identifier, timestamp } from "./contracts/common";
import { API_TICKET_SECONDS, canonicalJSON, decodeBase64URL, encodeBase64URL, hmacKey } from "./crypto";
import { OperationError } from "./errors";
import { AuthoritySchema } from "./routing";

export const DASHBOARD_AUTHORITY_HEADER = "x-cmux-v2-dashboard-authority";

export const DashboardAuthoritySchema = z.strictObject({
  authority: AuthoritySchema,
  origin: z.url().max(2048),
  clientInstanceId: identifier,
  canManageTeam: z.boolean(),
});
export const DashboardClaimsSchema = DashboardAuthoritySchema.extend({
  version: z.literal(2), audience: z.literal("cmux-iroh-dashboard-v2"),
  expiresAt: timestamp, keyId: identifier,
});
export type DashboardAuthority = z.infer<typeof DashboardAuthoritySchema>;
export type DashboardClaims = z.infer<typeof DashboardClaimsSchema>;
const encoder = new TextEncoder();

/** Domain-separated browser authority. It conveys no native endpoint proof. */
export async function issueDashboardTicket(session: DashboardAuthority, keyId: string, secret: string) {
  const claims = DashboardClaimsSchema.parse({ ...session, version: 2, audience: "cmux-iroh-dashboard-v2",
    expiresAt: session.authority.verifiedAt + API_TICKET_SECONDS, keyId });
  const body = encodeBase64URL(encoder.encode(canonicalJSON(claims)));
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret, "sign"), encoder.encode(body));
  return { token: body + "." + encodeBase64URL(new Uint8Array(signature)), expiresAt: claims.expiresAt,
    refreshAfter: claims.expiresAt - 300 };
}

export async function verifyDashboardTicket(token: string, keys: Readonly<Record<string, string>>,
  environment: string, projectId: string, origin: string, now: number): Promise<DashboardClaims> {
  try {
    if (token.length > 8192) throw new Error("Ticket size");
    const [body, signature, extra] = token.split(".");
    if (!body || !signature || extra !== undefined) throw new Error("Ticket shape");
    const claims = DashboardClaimsSchema.parse(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(decodeBase64URL(body))));
    const key = keys[claims.keyId];
    if (!key || !await crypto.subtle.verify("HMAC", await hmacKey(key, "verify"), decodeBase64URL(signature), encoder.encode(body))) throw new Error("Signature");
    if (claims.authority.environment !== environment || claims.authority.projectId !== projectId) throw new OperationError("environment_mismatch", 403);
    if (claims.origin !== origin) throw new OperationError("permission_denied", 403);
    if (claims.authority.verifiedAt > now + 30 || claims.expiresAt - claims.authority.verifiedAt !== API_TICKET_SECONDS) throw new Error("Ticket time");
    if (claims.expiresAt <= now) throw new OperationError("ticket_expired", 401, true);
    return claims;
  } catch (error) {
    if (error instanceof OperationError && ["environment_mismatch", "permission_denied", "ticket_expired"].includes(error.code)) throw error;
    throw new OperationError("unauthorized", 401);
  }
}
