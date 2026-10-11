// The pane-native transport's refusals (the Swift host checks every frame the page sends:
// .cmux-scratch/pane-protocol/pane-native-transport-review.md). They arrive as a JSON-RPC error
// whose data.code is `transport.*` (direct.ts copies it to `error.code`), or as a native reply's
// code (NativeError). The text is chosen by that code, never by the message, in the pane's language.
import { translate, type StringKey } from "./i18n";

const TRANSPORT_TEXT: Record<string, StringKey> = {
  "transport.gesture_required": "transport.gestureRequired",
  "transport.path_outside_roots": "transport.pathOutsideRoots",
  "transport.session_not_in_pane": "transport.sessionNotInPane",
  "transport.intent_invalid": "transport.intentInvalid",
  "transport.mode_not_confirmed": "transport.modeNotConfirmed",
};

/// The text to show for `error`: a transport refusal's own text (a code without one reads as the
/// generic refusal, never the host's English message), else the error's message.
export function errorMessage(error: unknown): string {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
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
