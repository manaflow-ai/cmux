// How a link in a reply reads (Leo 2026-10-20, "did we fix this bullshit yet"): an agent's bare
// `http://127.0.0.1:47811?token=…` printed its secret in full in a full-width card. A link now reads
// as text, its secret-looking query values as `•••`; the href keeps the real address, so a click
// still opens it. A local or private address is never dressed as a site (no chip, no preview).

/// The mask a secret value reads as.
export const REDACTED = "•••";

// A query or fragment parameter whose name, or one of its `_`/`-`/`.` parts, names a secret.
const SECRET_PART =
  /^(?:token|key|apikey|secret|auth|authorization|sig|signature|password|passwd|pwd|code|credential|credentials|session|sid|jwt|otp|nonce)$/i;
const SECRET_NAME = /token|secret|passw|apikey|signature|credential/i;

/// Whether a query parameter named `name` holds a secret (`token`, `api_key`, `X-Amz-Signature`,
/// `client_secret`, `code`).
export function isSecretParam(name: string): boolean {
  const decoded = safeDecode(name);
  return SECRET_NAME.test(decoded) || decoded.split(/[_.\-[\]]+/).some((part) => SECRET_PART.test(part));
}

/// `text` with the values of its secret-looking query and fragment parameters, and a password in
/// its user info, shown as `•••`. Everything else stays as written (no normalizing), so the shown
/// address still matches the reply.
export function redactUrlText(text: string): string {
  const masked = text.replace(/^([a-z][\w+.-]*:\/\/[^/?#@\s:]*):[^/?#@\s]+@/i, `$1:${REDACTED}@`);
  const at = masked.search(/[?#]/);
  if (at < 0) return masked;
  const tail = masked
    .slice(at)
    .replace(/([?&#;])([^=&#;\s]+)=([^&#;\s]*)/g, (whole, lead: string, name: string, value: string) =>
      value && isSecretParam(name) ? `${lead}${name}=${REDACTED}` : whole,
    );
  return masked.slice(0, at) + tail;
}

/// Whether `href` is on this machine or a private network: localhost (and `*.localhost`), loopback,
/// 0.0.0.0, RFC 1918, link-local, `.local`, and IPv6 loopback, unique-local and link-local. Such a
/// page is a dev server or a device, never a site to preview.
export function isPrivateUrl(href: string): boolean {
  let host: string;
  try {
    host = new URL(href).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host.startsWith("[") && host.endsWith("]")) {
    const v6 = host.slice(1, -1);
    return v6 === "::1" || v6 === "::" || /^f[cd][0-9a-f]{2}:/.test(v6) || /^fe[89ab][0-9a-f]:/.test(v6);
  }
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return true;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!v4) return false;
  const [a, b] = [Number(v4[1]), Number(v4[2])];
  return (
    a === 127 ||
    a === 10 ||
    a === 0 ||
    (a === 192 && b === 168) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 169 && b === 254) ||
    (a === 100 && b >= 64 && b <= 127)
  );
}

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}
