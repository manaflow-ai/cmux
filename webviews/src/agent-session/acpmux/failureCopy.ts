import type { Translate } from "./i18n";

/// Errors from harnesses are user-facing text, but their transport codes are not. Keep the
/// useful detail for ordinary failures while giving trust and authentication failures a plain
/// next step.
export function isAuthenticationFailure(message: string | undefined): boolean {
  if (!message) return false;
  return /(?:authenticat|oauth|unauthori[sz]ed|not logged in|login required|invalid (?:api )?key|\/login|\b401\b|token.{0,20}(?:expired|refresh))/i.test(
    message,
  );
}

export function failureCopy(t: Translate, message: string | undefined): string {
  if (!message) return t("turn.failed");
  if (/\btrust\.pending\b/i.test(message)) return t("trust.answerFirst");
  if (/\btrust\.untrusted\b/i.test(message)) return t("trust.untrustedNoPrompts");
  if (isAuthenticationFailure(message)) return t("turn.authExpired");
  return message;
}
