// The pane-native transport's refusals (the Swift host checks every frame the page sends:
// .cmux-scratch/pane-protocol/pane-native-transport-review.md). They arrive as a JSON-RPC error
// whose data.code is `transport.*` (direct.ts copies it to `error.code`), or as a native reply's
// code (NativeError). The text is chosen by that code, never by the message, in the pane's language.
import { translate, type StringKey } from "./i18n";

const TRANSPORT_TEXT: Record<string, StringKey> = {
  "transport.gesture_required": "transport.gestureRequired",
  "transport.path_outside_roots": "transport.pathOutsideRoots",
  "transport.person_required": "transport.personRequired",
  "transport.session_not_in_pane": "transport.sessionNotInPane",
  "transport.intent_invalid": "transport.intentInvalid",
  "transport.mode_not_confirmed": "transport.modeNotConfirmed",
  "transport.full_access_off": "transport.fullAccessOff",
};

// acpmux's own refusals (`data.reason`, which direct.ts copies to `error.reason`) that read the
// same as the pane host's: start_mode.rs refuses full access with `full_access_off`, and
// hub/person.rs an allow from a client that is not the person at the app with
// `permission.person_required`.
const DAEMON_REASON_CODE: Record<string, string> = {
  full_access_off: "transport.full_access_off",
  "permission.person_required": "transport.person_required",
};

function refusalCode(error: unknown): unknown {
  if (typeof error !== "object" || error === null) return undefined;
  const { code, reason } = error as { code?: unknown; reason?: unknown };
  if (typeof code === "string" && code.startsWith("transport.")) return code;
  return (typeof reason === "string" ? DAEMON_REASON_CODE[reason] : undefined) ?? code;
}

/// Whether the pane's host or acpmux refused the request with a reason the user should see.
export function isHostRefusal(error: unknown): boolean {
  const code = refusalCode(error);
  return typeof code === "string" && code.startsWith("transport.");
}

// acpmux's refusals the pane words itself (`data.reason`; the daemon's message stays English for
// its CLI): the folder-trust gate (server/trust_gate.rs, hub/pool/mod.rs). They are not host
// refusals: the pane's trust route asks the question.
const DAEMON_REASON_TEXT: Record<string, StringKey> = {
  "trust.pending": "error.trustPending",
  "trust.untrusted": "error.trustUntrusted",
};

/// The text to show for `error`: a transport refusal's own text (a code without one reads as the
/// generic refusal, never the host's English message), acpmux's worded reasons, else the error's
/// message.
export function errorMessage(error: unknown): string {
  const reason = typeof error === "object" && error !== null ? (error as { reason?: unknown }).reason : undefined;
  const reasonKey = typeof reason === "string" ? DAEMON_REASON_TEXT[reason] : undefined;
  if (reasonKey) return translate(reasonKey);
  const code = refusalCode(error);
  const key =
    typeof code === "string"
      ? (TRANSPORT_TEXT[code] ?? (code.startsWith("transport.") ? "transport.refused" : undefined))
      : undefined;
  if (key) {
    // A malformed request is the pane's bug, not the user's: log it, show the generic text.
    if (code === "transport.intent_invalid") console.error("agent pane: the host refused a request", error);
    return translate(key);
  }
  if (error instanceof Error) return error.message;
  return typeof error === "string" ? error : "";
}

/// A New Tab start that ended because it was cancelled, not because it failed: Not now on the
/// folder's Trust question, a newer folder request, or another chat or another start taking the page
/// before it finished. Its sender settles (the page can send again), and no notice calls it a failure.
const START_CANCELLED = "start.cancelled";

export function startCancelled(): Error {
  return Object.assign(new Error(translate("switch.cancelled")), { code: START_CANCELLED });
}

export function isStartCancelled(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { code?: unknown }).code === START_CANCELLED;
}
