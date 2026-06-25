import { promises as dns } from "node:dns";

/**
 * Result of checking whether an email address can plausibly receive mail.
 * - `ok`: the domain publishes a usable MX (or an A/AAAA fallback per RFC 5321).
 * - `invalid`: the domain definitively cannot receive mail (no such domain, or
 *   an explicit "null MX" per RFC 7505), or it is a known disposable provider.
 * - `unknown`: the lookup hit a transient DNS failure. Callers should fail open
 *   (treat as deliverable) so a resolver hiccup never blocks a real signup.
 */
export type EmailCheck = "ok" | "invalid" | "unknown";

/**
 * Well-known disposable / single-use inbox providers. Deliberately conservative:
 * it targets services whose entire purpose is throwaway inboxes, not privacy
 * forwarders that real users rely on (e.g. passmail.com, duck.com, simplelogin).
 * For a fuller (~3.5k domain) list, swap in the `disposable-email-domains`
 * package; this hard-coded set avoids a dependency and stays predictable.
 */
export const DISPOSABLE_EMAIL_DOMAINS: ReadonlySet<string> = new Set([
  "mailinator.com",
  "10minutemail.com",
  "guerrillamail.com",
  "guerrillamail.info",
  "sharklasers.com",
  "grr.la",
  "yopmail.com",
  "yopmail.fr",
  "tempmail.com",
  "temp-mail.org",
  "trashmail.com",
  "trashmail.de",
  "getnada.com",
  "nada.email",
  "maildrop.cc",
  "dispostable.com",
  "fakeinbox.com",
  "throwawaymail.com",
  "mohmal.com",
  "moakt.com",
  "tempr.email",
  "discard.email",
  "33mail.com",
  "spamgourmet.com",
  "mailnesia.com",
  "mintemail.com",
  "emailondeck.com",
  "tempmailo.com",
  "mail7.io",
  "inboxkitten.com",
  "tmpmail.org",
  "1secmail.com",
  "1secmail.org",
  "1secmail.net",
  "vjuum.com",
  "laafd.com",
  "txcct.com",
]);

// Cache resolved domains so repeat submits and the two-phase validate/notify
// round trips don't re-query DNS. Bounded so it can't grow without limit.
const CACHE_TTL_MS = 10 * 60 * 1000;
const CACHE_MAX = 2000;
const cache = new Map<string, { status: EmailCheck; expires: number }>();

function cacheGet(domain: string): EmailCheck | null {
  const hit = cache.get(domain);
  if (!hit) return null;
  if (hit.expires < Date.now()) {
    cache.delete(domain);
    return null;
  }
  return hit.status;
}

function cacheSet(domain: string, status: EmailCheck): void {
  if (cache.size >= CACHE_MAX) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(domain, { status, expires: Date.now() + CACHE_TTL_MS });
}

// ENOTFOUND/ENODATA are definitive "this record does not exist" answers; any
// other DNS error (ETIMEOUT, ESERVFAIL, EREFUSED, …) is transient.
function isNoSuchRecord(err: unknown): boolean {
  const code = (err as NodeJS.ErrnoException | null)?.code;
  return code === "ENOTFOUND" || code === "ENODATA";
}

async function classifyAddress(
  lookup: Promise<string[]>,
): Promise<"ok" | "miss" | "transient"> {
  try {
    return (await lookup).length > 0 ? "ok" : "miss";
  } catch (err) {
    return isNoSuchRecord(err) ? "miss" : "transient";
  }
}

// No MX record: RFC 5321 §5.1 treats the domain's A/AAAA address as an implicit
// mail exchanger, so a domain with only an address record can still receive
// mail. Run A and AAAA in parallel so this (rare, MX-less) fallback path never
// pays two sequential lookups.
async function hasAddressRecord(domain: string): Promise<EmailCheck> {
  const [a, aaaa] = await Promise.all([
    classifyAddress(dns.resolve4(domain)),
    classifyAddress(dns.resolve6(domain)),
  ]);
  if (a === "ok" || aaaa === "ok") return "ok";
  if (a === "transient" || aaaa === "transient") return "unknown";
  return "invalid";
}

async function resolveDomain(domain: string): Promise<EmailCheck> {
  try {
    const mx = await dns.resolveMx(domain);
    const usable = mx.filter((r) => r.exchange && r.exchange !== ".");
    if (usable.length > 0) return "ok";
    // Records exist but every one is a "null MX" (RFC 7505, exchange ".") — the
    // domain is explicitly declaring it accepts no mail.
    if (mx.length > 0) return "invalid";
  } catch (err) {
    // Transient resolver failure: fail open rather than reject a real address.
    if (!isNoSuchRecord(err)) return "unknown";
  }
  return hasAddressRecord(domain);
}

/**
 * Checks whether `email`'s domain can plausibly receive mail. Catches typos
 * (`gmail.con`), nonexistent domains, null-MX domains, and known disposable
 * providers, without proving inbox ownership. Returns `unknown` on transient
 * DNS failures so callers can fail open.
 */
export async function checkEmailDeliverable(email: string): Promise<EmailCheck> {
  const at = email.lastIndexOf("@");
  if (at < 0) return "invalid";
  const domain = email
    .slice(at + 1)
    .trim()
    .toLowerCase()
    .replace(/\.$/, "");
  if (!domain || domain.includes("@")) return "invalid";
  if (DISPOSABLE_EMAIL_DOMAINS.has(domain)) return "invalid";

  const cached = cacheGet(domain);
  if (cached) return cached;

  const status = await resolveDomain(domain);
  // Cache only stable answers; let `unknown` retry on the next submit.
  if (status !== "unknown") cacheSet(domain, status);
  return status;
}
