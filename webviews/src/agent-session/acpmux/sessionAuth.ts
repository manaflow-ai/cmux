/** The session/selected-route auth verdict from acpmux. Unknown is never a refusal. */
export type SessionAuthState =
  | "ready" | "signedOut" | "expired" | "routeAuthNeeded"
  | "routeUnreachable" | "peerUnreachable" | "unknown";
export type SessionAuthSource = "peerLink" | "routeProbe" | "turn" | "authCheck" | "none";
export type SessionAuth = {
  state: SessionAuthState;
  source: SessionAuthSource;
  evidenceAt: number | null;
  detail?: string;
  harness?: string;
  host?: string | null;
  routeId?: string | null;
  fromSessionId?: string | null;
  login?: { kind: "terminal" | "route"; command?: string; host?: string; routeId?: string };
};
export const UNKNOWN_AUTH: SessionAuth = { state: "unknown", source: "none", evidenceAt: null };
const states = new Set<SessionAuthState>([
  "ready", "signedOut", "expired", "routeAuthNeeded",
  "routeUnreachable", "peerUnreachable", "unknown",
]);
const sources = new Set<SessionAuthSource>(["peerLink", "routeProbe", "turn", "authCheck", "none"]);
export function readSessionAuth(reply: unknown): SessionAuth {
  if (!reply || typeof reply !== "object") return UNKNOWN_AUTH;
  const row = reply as Record<string, unknown>;
  if (!states.has(row.state as SessionAuthState) || !sources.has(row.source as SessionAuthSource)) return UNKNOWN_AUTH;
  if ((row.state === "signedOut" || row.state === "expired" || row.state === "routeAuthNeeded") && row.source === "none") return UNKNOWN_AUTH;
  const login = row.login && typeof row.login === "object" ? row.login as Record<string, unknown> : undefined;
  return {
    state: row.state as SessionAuthState,
    source: row.source as SessionAuthSource,
    evidenceAt: typeof row.evidenceAt === "number" && Number.isFinite(row.evidenceAt) ? row.evidenceAt : null,
    ...(typeof row.detail === "string" ? { detail: row.detail } : {}),
    ...(typeof row.harness === "string" ? { harness: row.harness } : {}),
    ...(typeof row.host === "string" || row.host === null ? { host: row.host as string | null } : {}),
    ...(typeof row.routeId === "string" || row.routeId === null ? { routeId: row.routeId as string | null } : {}),
    ...(typeof row.fromSessionId === "string" || row.fromSessionId === null ? { fromSessionId: row.fromSessionId as string | null } : {}),
    ...(login && (login.kind === "terminal" || login.kind === "route") ? { login: {
      kind: login.kind,
      ...(typeof login.command === "string" ? { command: login.command } : {}),
      ...(typeof login.host === "string" ? { host: login.host } : {}),
      ...(typeof login.routeId === "string" ? { routeId: login.routeId } : {}),
    } } : {}),
  };
}
export function authBlocksSend(auth: SessionAuth | undefined): boolean {
  return auth?.state === "signedOut" || auth?.state === "expired" || auth?.state === "routeAuthNeeded";
}
export function authText(auth: SessionAuth | undefined): string | undefined {
  if (!auth) return undefined;
  const label = auth.state === "signedOut" ? "Sign in required"
    : auth.state === "expired" ? "Session expired · sign in again"
    : auth.state === "routeAuthNeeded" ? "Route needs sign in"
    : auth.state === "routeUnreachable" ? "Account route unreachable"
    : auth.state === "peerUnreachable" ? "Machine unreachable"
    : undefined;
  if (!label) return undefined;
  const detail = auth.detail ?? auth.login?.command;
  return detail ? `${label}: ${detail}` : label;
}

export function authChipText(auth: SessionAuth | undefined): string | undefined {
  switch (auth?.state) {
    case "signedOut": return "Sign in";
    case "expired": return "Re-authenticate";
    case "routeAuthNeeded": return "Route sign in";
    case "routeUnreachable": return "Route offline";
    case "peerUnreachable": return "Machine offline";
    default: return undefined;
  }
}
