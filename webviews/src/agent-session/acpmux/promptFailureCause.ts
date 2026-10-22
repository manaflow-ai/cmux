// Why a prompt did not get there, as Retry can act on it (Leo, 2026-10-21: Retry showed under
// prompts it could never send). Read from the refusal's structured code (`data.code`, the pane
// host's `transport.*`) and acpmux's `data.reason` and `data.retryable`, which direct.ts keeps on
// the row's delivery; never from the message, whose words are for the person and change.
//
// - `transient`: anything that may work the next time (acpmux never answered, the agent's turn
//   failed, a refusal for want of a gesture, whose Retry click is the gesture, a refusal acpmux
//   marks `retryable`). Retry.
// - `connection`: the pane lost its connection to acpmux. Retry once the pane is connected again.
// - `trust`: acpmux holds prompts while the folder's trust question is open, or after Don't trust
//   (`trust_gate.rs`). Retry once the folder is trusted; the question itself is the way out.
// - `person`: a refusal only a person at the Mac can lift (a confirmation sheet, a setting, a
//   question only the app answers). Never Retry: the same request is refused again.
// - `unsupported`: a request the host or acpmux does not accept, one acpmux marks as not
//   retryable, a refusal the pane has no cause for (a new `transport.*` code or acpmux reason,
//   unless acpmux marks it retryable), and a failed row with no delivery (an older session's,
//   with nothing kept to send again). Never Retry.
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

/// Whether the folder's trust still holds a prompt acpmux refused for it (RetryGate.trustBlocked),
/// from useFolderTrustAsk: until the pane knows the folder is trusted. A read in flight (`blocked`
/// with no reason, right after a `trust.pending` refusal), an open question, Don't trust and a
/// read that came back with no answer all hold: acpmux would refuse the same prompt again.
export function trustHolds(trust: { blocked?: object; trusted: boolean }): boolean {
  return Boolean(trust.blocked) || !trust.trusted;
}

const TRUST_REASONS = new Set(["trust.pending", "trust.untrusted"]);

/// Refusals that wait on a person at the Mac: the pane host's confirmation sheets and settings
/// (AgentPaneTransportTypes.swift), and acpmux's questions only the app answers.
const PERSON = new Set([
  "transport.person_required",
  "permission.person_required",
  "person_required",
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

/// The pane's own word that its connection to acpmux went (bridgeSocket.ts, direct.ts): the same
/// prompt can go once the pane is connected again.
const CONNECTION_LOST = new Set(["transport.closed", "transport.stale_connection", "native.not_connected"]);

/// Failures that may work the next time: acpmux never answered (direct.ts `timeout`), and a
/// refusal for want of a gesture, whose Retry click is the gesture.
const TRANSIENT = new Set(["timeout", "native.timed_out", "transport.gesture_required"]);

export function promptFailureCause(
  delivery: Pick<PromptDelivery, "code" | "reason" | "retryable" | "hop"> | undefined,
): PromptFailureCause {
  // No delivery, no prompt kept to send again (direct.ts `retryPrompt` finds nothing).
  if (!delivery) return "unsupported";
  const { code, reason } = delivery;
  if (reason && TRUST_REASONS.has(reason)) return "trust";
  if ((code && PERSON.has(code)) || (reason && PERSON.has(reason))) return "person";
  if ((code && UNSUPPORTED.has(code)) || (reason && UNSUPPORTED.has(reason))) return "unsupported";
  // acpmux says so itself (peer_link.rs `unreachable_error`, launch_policy.rs).
  if (delivery.retryable === false) return "unsupported";
  if (delivery.retryable === true) return "transient";
  if (code && CONNECTION_LOST.has(code)) return "connection";
  if (code && TRANSIENT.has(code)) return "transient";
  // A refusal the pane has no cause for: the same request is likely refused again. direct.ts
  // labels any transport refusal as the connection's hop, so the hop says nothing here.
  if (reason || code?.startsWith("transport.")) return "unsupported";
  return "transient";
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
