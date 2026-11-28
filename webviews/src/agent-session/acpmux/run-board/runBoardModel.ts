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

/// Opens a worker's terminal for the person's Attach click: asks for a one-use ticket and hands it
/// to the host. A ticket that expired before it was used, or that the server says was already
/// consumed, is the board's to replace, not the person's: requesting a fresh one is safe, so it asks
/// once more on the same click instead of showing "Attach expired · Retry" (Leo, 2026-11-22: "vacuous
/// decisions like that should be just done"). Answers the ticket opened, or undefined when no
/// ticket bridge exists; throws what the last try failed with.
export async function attachWithFreshTicket<T extends AttachTicket>(
  request: () => Promise<T | void | undefined>,
  open: (ticket: T) => Promise<void>,
  now: () => number = Date.now,
): Promise<T | undefined> {
  const once = async (): Promise<T | undefined> => {
    const ticket = (await request()) || undefined;
    if (ticket && attachTicketExpired(ticket, now()))
      throw new RunApiHttpError(410, "This attach ticket has expired.", "run_attach_expired");
    if (ticket) await open(ticket);
    return ticket;
  };
  try {
    return await once();
  } catch (error) {
    if (attachFailureState(error) === "error") throw error;
    return await once();
  }
}
