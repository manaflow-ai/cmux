import { postNative } from "../native";
import { RunApiHttpError, type RunAttachTicket } from "./runApi";

type RunEndpoint = {
  transport?: unknown;
  route?: unknown;
  session?: unknown;
  trustedCarrier?: unknown;
  expiresAtUnix?: unknown;
};

export type RunAttachNative = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

function endpointOf(ticket: RunAttachTicket): RunEndpoint {
  const endpoint = ticket.endpoint;
  return endpoint && typeof endpoint === "object" ? endpoint : ticket;
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

/**
 * Builds the command understood by the existing cmux terminal bridge. The
 * redeemed route is a short-lived capability; it is passed only to the
 * terminal process and never persisted by the board.
 */
export function runAttachCommand(ticket: RunAttachTicket, now = Date.now()): string {
  const endpoint = endpointOf(ticket);
  const expiry = typeof endpoint.expiresAtUnix === "number" ? endpoint.expiresAtUnix : ticket.expiresAtUnix;
  if (typeof expiry === "number" && Number.isFinite(expiry) && expiry * 1_000 <= now) {
    throw new RunApiHttpError(410, "This worker terminal endpoint has expired. Request a fresh attach ticket.", "run_attach_expired");
  }
  if (endpoint.transport !== "cmux-remote" || typeof endpoint.route !== "string" || !endpoint.route) {
    throw new RunApiHttpError(409, "This worker does not expose a cmux terminal endpoint.", "run_attach_transport_unsupported");
  }
  if (endpoint.trustedCarrier !== true) {
    throw new RunApiHttpError(409, "This worker requires device enrollment before terminal attach.", "run_attach_enrollment_required");
  }
  if (typeof endpoint.session !== "string" || !endpoint.session) {
    throw new RunApiHttpError(502, "Run attach returned no worker session.", "run_attach_invalid");
  }
  return [
    "cmux",
    "remote",
    "connect",
    shellQuote(endpoint.route),
    "--session",
    shellQuote(endpoint.session),
    "--carrier",
  ].join(" ");
}

/**
 * Opens the worker in a real cmux terminal tab through the existing pane
 * bridge. `tab.open` owns tab creation and starts the command in that tab, so
 * the Run board never has to own a socket, daemon, or terminal lifetime.
 */
export async function attachRunTerminal(ticket: RunAttachTicket, send: RunAttachNative = postNative): Promise<void> {
  await send("tab.open", {
    kind: "terminal",
    text: runAttachCommand(ticket),
    run: true,
    keep: true,
  });
}
