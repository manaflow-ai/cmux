import { translate } from "../i18n";
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

/** Builds a safe CLI fallback for hosts that need to open the worker manually. */
export function runAttachCommand(ticket: RunAttachTicket, now = Date.now()): string {
  const endpoint = endpointOf(ticket);
  const expiry = typeof endpoint.expiresAtUnix === "number" ? endpoint.expiresAtUnix : ticket.expiresAtUnix;
  if (typeof expiry === "number" && Number.isFinite(expiry) && expiry * 1_000 <= now) {
    throw new RunApiHttpError(410, translate("runBoard.error.attachExpired"), "run_attach_expired");
  }
  if (endpoint.transport !== "cmux-remote" || typeof endpoint.route !== "string" || !endpoint.route) {
    throw new RunApiHttpError(
      409,
      translate("runBoard.error.attachTransportUnsupported"),
      "run_attach_transport_unsupported",
    );
  }
  if (endpoint.trustedCarrier !== true) {
    throw new RunApiHttpError(
      409,
      translate("runBoard.error.attachEnrollmentRequired"),
      "run_attach_enrollment_required",
    );
  }
  if (typeof endpoint.session !== "string" || !endpoint.session) {
    throw new RunApiHttpError(502, translate("runBoard.error.attachNoSession"), "run_attach_invalid");
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
 * Opens the worker in a real cmux terminal/session through the native bridge.
 * The host resolves the redeemed VM and terminal ids against its enrolled
 * daemon registry; route credentials never enter a shell command.
 */
export async function attachRunTerminal(ticket: RunAttachTicket, send: RunAttachNative = postNative): Promise<void> {
  const endpoint = endpointOf(ticket);
  // The native bridge resolves the redeemed VM/terminal ids against its
  // enrolled daemon registry. The route is intentionally not sent to a shell,
  // where it could land in argv or history.
  await send("run.attach", {
    runId: ticket.runId,
    attemptId: ticket.attemptId,
    provider: ticket.provider,
    providerVmId: ticket.providerVmId,
    providerWorkspaceId: ticket.providerWorkspaceId,
    providerTerminalId: ticket.providerTerminalId,
    route: endpoint.route,
    session: endpoint.session,
    trustedCarrier: endpoint.trustedCarrier,
    expiresAtUnix: endpoint.expiresAtUnix ?? ticket.expiresAtUnix,
  });
}
