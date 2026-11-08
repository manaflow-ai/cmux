/**
 * Return the stable comparison form used when matching billing email
 * addresses to Stack accounts.
 *
 * Gmail treats dots in the local part as presentation-only, while plus tags
 * remain meaningful mailbox aliases. Gmail's legacy googlemail.com domain is
 * also the same mailbox namespace. Other providers are compared only after
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
  return `${mailbox}@gmail.com`;
}

/** Return whether an address belongs to Gmail's dot-insensitive namespace. */
export function isGmailAddress(value: string): boolean {
  const normalized = value.trim().toLowerCase();
  const at = normalized.lastIndexOf("@");
  if (at <= 0 || at === normalized.length - 1) return false;
  const domain = normalized.slice(at + 1);
  return domain === "gmail.com" || domain === "googlemail.com";
}

/**
 * Return the spellings that provider lookups may use for one mailbox.
 * Canonical comparison still happens after the lookup, but querying both
 * Gmail domains is required because provider email filters are literal.
 */
export function emailVariantsForMatching(value: string): readonly string[] {
  const normalized = value.trim().toLowerCase();
  const canonical = canonicalizeEmailForMatching(normalized);
  const variants = new Set<string>([canonical, normalized]);
  const at = normalized.lastIndexOf("@");
  const canonicalAt = canonical.lastIndexOf("@");
  if (at > 0 && canonicalAt > 0 && isGmailAddress(normalized)) {
    const localParts = new Set([
      normalized.slice(0, at),
      canonical.slice(0, canonicalAt),
    ]);
    for (const local of localParts) {
      variants.add(`${local}@gmail.com`);
      variants.add(`${local}@googlemail.com`);
    }
  }
  return [...variants].filter(Boolean);
}
