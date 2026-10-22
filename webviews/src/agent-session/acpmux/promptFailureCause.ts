// Why a prompt did not get there, as Retry can act on it (Leo, 2026-10-21: Retry showed under
// prompts it could never send). Read from the refusal's structured code (`data.code`, the pane
// host's `transport.*`) and acpmux's `data.reason` and `data.retryable`, which direct.ts keeps on
// the row's delivery; never from the message, whose words are for the person and change.
//
// - `transient`: anything that may work the next time (acpmux never answered, the agent's turn
//   failed, a refusal for want of a gesture, whose Retry click is the gesture). Retry.
// - `connection`: the pane could not reach acpmux. Retry once the pane is connected again.
// - `trust`: acpmux holds prompts while the folder's trust question is open, or after Don't trust
//   (`trust_gate.rs`). Retry once the folder is trusted; the question itself is the way out.
// - `person`: a refusal only a person at the Mac can lift (a confirmation sheet, a setting, a
//   question only the app answers). Never Retry: the same request is refused again.
// - `unsupported`: a request the host or acpmux does not accept, or one acpmux marks as not
//   retryable. Never Retry.
// Edit, Remove and Details stay on every cause.
import { createContext } from "react";
import type { PromptDelivery } from "./model";

export type PromptFailureCause = "transient" | "connection" | "trust" | "person" | "unsupported";

/// What the pane knows now that decides whether a held cause has cleared.
export type RetryGate = {
  /// The folder's trust question is open, or the answer was Don't trust (useFolderTrustAsk.ts `blocked`).
  trustBlocked: boolean;
  /// The pane has a connection to acpmux (not disconnected or reconnecting).
  connected: boolean;
};

/// Without a provider (a row drawn alone, a gallery fixture) nothing holds a Retry back.
export const RetryGateContext = createContext<RetryGate>({ trustBlocked: false, connected: true });

const TRUST_REASONS = new Set(["trust.pending", "trust.untrusted"]);

/// Refusals that wait on a person at the Mac: the pane host's confirmation sheets and settings
/// (AgentPaneTransportTypes.swift), and acpmux's questions only the app answers.
const PERSON = new Set([
  "transport.mode_not_confirmed",
  "transport.harness_not_confirmed",
  "transport.full_access_off",
  "full_access_off",
  "trust.web_cannot_answer",
  "trust.remote",
  "remote.mode_not_asking",
  "remote.policy_not_asking",
]);

/// Requests the pane host or acpmux does not accept: sending the same one again is refused again.
const UNSUPPORTED = new Set([
  "transport.method_refused",
  "transport.intent_invalid",
  "transport.invalid_frame",
  "transport.frame_too_large",
  "transport.first_frame",
  "transport.duplicate_key",
  "transport.mcp_servers_refused",
  "transport.path_invalid",
  "transport.path_outside_roots",
  "transport.session_not_in_pane",
  "trust.peer_unsupported",
  "too_large",
  "message.too_large",
]);

export function promptFailureCause(
  delivery: Pick<PromptDelivery, "code" | "reason" | "retryable" | "hop"> | undefined,
): PromptFailureCause {
  if (!delivery) return "transient";
  const { code, reason } = delivery;
  if (reason && TRUST_REASONS.has(reason)) return "trust";
  if ((code && PERSON.has(code)) || (reason && PERSON.has(reason))) return "person";
  if ((code && UNSUPPORTED.has(code)) || (reason && UNSUPPORTED.has(reason))) return "unsupported";
  // acpmux says so itself (peer_link.rs `unreachable_error`, launch_policy.rs).
  if (delivery.retryable === false) return "unsupported";
  if (delivery.retryable === true) return "transient";
  if (delivery.hop === "connection") return "connection";
  return "transient";
}

/// Whether acpmux may have taken the prompt though it never said so: it gave no answer in time
/// (direct.ts `timeout`; a late acceptance still lands). Such a prompt goes again only under its own
/// prompt id with `resend`, which acpmux runs once, so it never joins a run (failedPromptGroups.ts).
export function mayHaveBeenTaken(delivery: Pick<PromptDelivery, "code"> | undefined): boolean {
  return delivery?.code === "timeout";
}

/// Whether Retry can work for `cause` now.
export function canRetry(cause: PromptFailureCause, gate: RetryGate): boolean {
  switch (cause) {
    case "transient":
      return true;
    case "connection":
      return gate.connected;
    case "trust":
      return !gate.trustBlocked;
    case "person":
    case "unsupported":
      return false;
  }
}
