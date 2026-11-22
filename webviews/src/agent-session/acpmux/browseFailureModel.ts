import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";

/// Native folder chooser failures use a transport code when one is available. Keep the shared
/// fallback localized and useful when a host gives us no displayable reason.
export function browseFailureMessage(error: unknown): string {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  if (code === "unsupported") return translate("project.unavailable");
  return errorMessage(error).trim() || translate("project.unavailable");
}
