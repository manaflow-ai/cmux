import {
  createHash,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

export const PUBLICATION_SESSION_COOKIE = "__Host-cmux-preview";
export const PUBLICATION_TRANSACTION_COOKIE = "__Host-cmux-preview-tx";
export const PUBLICATION_CALLBACK_PATH = "/_cmux/auth/callback";

const MAX_RETURN_PATH_LENGTH = 2_048;
const PUBLICATION_TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,256}$/u;

/** Random URL-safe material used for browser capabilities and one-time codes. */
export function randomPublicationToken(bytes = 32): string {
  return randomBytes(bytes).toString("base64url");
}

/** Only hashes of bearer capabilities are persisted. */
export function hashPublicationToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** RFC 7636 S256 challenge for the verifier held by the publication origin. */
export function publicationPkceChallenge(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url");
}

/** A transaction cookie binds the public transaction handle to its PKCE verifier. */
export function publicationTransactionCookieValue(
  transaction: string,
  verifier: string,
): string {
  if (!isPublicationToken(transaction) || !isPublicationToken(verifier)) {
    throw new Error("Publication transaction cookie contains invalid token material");
  }
  return `${transaction}.${verifier}`;
}

/** Decode only the exact transaction-cookie format minted above. */
export function parsePublicationTransactionCookie(
  value: string | null,
): { readonly transaction: string; readonly verifier: string } | null {
  if (!value) return null;
  const pieces = value.split(".");
  if (pieces.length !== 2) return null;
  const [transaction, verifier] = pieces;
  return transaction && verifier &&
      isPublicationToken(transaction) && isPublicationToken(verifier)
    ? { transaction, verifier }
    : null;
}

/** Validate URL-visible transaction, state, and authorization-code material. */
export function isPublicationToken(value: string | null): value is string {
  return value !== null && PUBLICATION_TOKEN_PATTERN.test(value);
}

/** Compare service credentials without leaking a matching prefix. */
export function publicationSecretMatches(
  presented: string | null,
  expected: string | undefined,
): boolean {
  if (!presented || !expected) return false;
  const presentedDigest = createHash("sha256").update(presented).digest();
  const expectedDigest = createHash("sha256").update(expected).digest();
  return timingSafeEqual(presentedDigest, expectedDigest);
}

/** Normalize one exact public hostname; wildcard publications are not accepted. */
export function normalizePublicationHostname(value: string): string | null {
  const candidate = value.trim().toLowerCase().replace(/\.$/u, "");
  if (!candidate || candidate.length > 253 || candidate.includes("*")) return null;
  try {
    const url = new URL(`https://${candidate}`);
    if (
      url.hostname !== candidate ||
      url.port ||
      url.username ||
      url.password ||
      url.pathname !== "/" ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    const labels = candidate.split(".");
    if (
      labels.length < 2 ||
      labels.some((label) =>
        !label ||
        label.length > 63 ||
        !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label)
      )
    ) {
      return null;
    }
    return candidate;
  } catch {
    return null;
  }
}

/** Extract and normalize the hostname from an HTTP Host-style value. */
export function publicationHostnameFromHeader(value: string | null): string | null {
  if (!value) return null;
  try {
    return normalizePublicationHostname(new URL(`https://${value.trim()}`).hostname);
  } catch {
    return null;
  }
}

/** Keep post-auth navigation on the publication origin and away from the callback. */
export function safePublicationReturnPath(value: string | null): string {
  if (
    !value ||
    value.length > MAX_RETURN_PATH_LENGTH ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    value.startsWith("/\\")
  ) {
    return "/";
  }
  try {
    const parsed = new URL(value, "https://publication.invalid");
    if (parsed.origin !== "https://publication.invalid") return "/";
    if (parsed.pathname === PUBLICATION_CALLBACK_PATH) return "/";
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    return "/";
  }
}

/** Read one cookie without treating malformed siblings as authentication data. */
export function publicationCookie(
  header: string | null,
  name: string,
): string | null {
  if (!header) return null;
  for (const pair of header.split(";")) {
    const separator = pair.indexOf("=");
    if (separator < 0 || pair.slice(0, separator).trim() !== name) continue;
    const value = pair.slice(separator + 1).trim();
    return value || null;
  }
  return null;
}

/** Host-only cookie instructions relayed by Freestyle on the publication origin. */
export function publicationCookieHeader(
  name: typeof PUBLICATION_SESSION_COOKIE | typeof PUBLICATION_TRANSACTION_COOKIE,
  value: string,
  maxAgeSeconds: number,
): string {
  return `${name}=${value}; Path=/; Max-Age=${maxAgeSeconds}; Secure; HttpOnly; SameSite=Lax`;
}

/** Expire a host-only publication cookie. */
export function clearPublicationCookieHeader(
  name: typeof PUBLICATION_SESSION_COOKIE | typeof PUBLICATION_TRANSACTION_COOKIE,
): string {
  return publicationCookieHeader(name, "", 0);
}
