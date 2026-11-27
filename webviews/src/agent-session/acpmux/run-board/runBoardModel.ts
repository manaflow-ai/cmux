import { RunApiHttpError, type AttachTicket } from "./runApi";

export type RunBoardAttachState = "idle" | "attached" | "expired" | "replayed" | "error";

export function attachFailureState(error: unknown): Exclude<RunBoardAttachState, "idle" | "attached"> {
  if (error instanceof RunApiHttpError) {
    const code = error.code?.toLowerCase() ?? "";
    if (error.status === 410 || code.includes("expired") || code.includes("expire")) return "expired";
    if (error.status === 409 && (code.includes("replay") || code.includes("consum"))) return "replayed";
  }
  return "error";
}

export function attachTicketExpired(ticket: AttachTicket, now = Date.now()): boolean {
  const unix = ticket.expiresAtUnix;
  if (typeof unix === "number" && Number.isFinite(unix)) return (unix > 10_000_000_000 ? unix : unix * 1_000) <= now;
  if (ticket.expiresAt === undefined) return false;
  const millis = typeof ticket.expiresAt === "number" ? ticket.expiresAt : Date.parse(ticket.expiresAt);
  return Number.isFinite(millis) && millis <= now;
}
