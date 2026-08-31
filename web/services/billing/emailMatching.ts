/**
 * Return the stable comparison form used when matching billing email
 * addresses to Stack accounts.
 *
 * Gmail treats dots in the local part as presentation-only, while plus tags
 * remain meaningful mailbox aliases. Other providers are compared only after
 * trimming and lowercasing; their local-part spelling is preserved.
 */
export function canonicalizeEmailForMatching(value: string): string {
  const normalized = value.trim().toLowerCase();
  const at = normalized.lastIndexOf("@");
  if (at <= 0 || at === normalized.length - 1) return normalized;

  const local = normalized.slice(0, at);
  const domain = normalized.slice(at + 1);
  if (domain !== "gmail.com" && domain !== "googlemail.com") {
    return normalized;
  }
  const plusIndex = local.indexOf("+");
  const mailbox = plusIndex < 0
    ? local.replaceAll(".", "")
    : `${local.slice(0, plusIndex).replaceAll(".", "")}${local.slice(plusIndex)}`;
  return `${mailbox}@${domain}`;
}
