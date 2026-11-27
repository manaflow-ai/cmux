/**
 * Svix webhook signatures (Stack Auth delivers its webhooks through Svix). The
 * signed content is `${svix-id}.${svix-timestamp}.${raw body}`, HMAC-SHA256
 * with the endpoint secret (`whsec_` + base64 key bytes); `svix-signature` is
 * a space-separated list of `v1,<base64 signature>`, so during a secret
 * rotation one delivery carries a signature per secret and any match passes.
 * A timestamp more than 5 minutes from the receiver's clock is refused, so a
 * captured delivery cannot be replayed later; within the window, the
 * receiver's svix-id record makes a retry a no-op.
 *
 * Pure (Web Crypto only), shared by workers/cmux-vm and backend/apps/api so
 * the two receivers never diverge.
 */

export const SVIX_TOLERANCE_SECONDS = 5 * 60

export type SvixSignatureCheck =
  | { readonly ok: true; readonly messageId: string }
  | { readonly ok: false; readonly reason: "headers" | "stale" | "signature" | "secret" }

/** The few header reads the check needs (a fetch `Headers` fits). */
export interface SvixHeaders {
  get(name: string): string | null
}

const base64ToBytes = (value: string): Uint8Array | null => {
  try {
    const binary = atob(value)
    return Uint8Array.from(binary, (char) => char.charCodeAt(0))
  } catch {
    return null
  }
}

const bytesToBase64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes))

/** Equal-length strings compared without an early exit. */
const constantTimeEqual = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/** The base64 signature for `content` under `secret`; null when the secret is not a valid key. */
export async function signSvixContent(secret: string, content: string): Promise<string | null> {
  const raw = secret.trim()
  const key = base64ToBytes(raw.startsWith("whsec_") ? raw.slice("whsec_".length) : raw)
  if (key === null || key.length < 16) return null
  const hmac = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const signature = await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(content))
  return bytesToBase64(new Uint8Array(signature))
}

export async function verifySvixSignature(secret: string, headers: SvixHeaders, body: string, nowMs: number): Promise<SvixSignatureCheck> {
  const id = headers.get("svix-id") ?? ""
  const timestamp = headers.get("svix-timestamp") ?? ""
  const signatures = headers.get("svix-signature") ?? ""
  if (id.length === 0 || id.length > 256 || !/^[0-9]{1,12}$/u.test(timestamp) || signatures.length === 0 || signatures.length > 4096) {
    return { ok: false, reason: "headers" }
  }
  if (Math.abs(nowMs / 1000 - Number(timestamp)) > SVIX_TOLERANCE_SECONDS) return { ok: false, reason: "stale" }
  const expected = await signSvixContent(secret, `${id}.${timestamp}.${body}`)
  if (expected === null) return { ok: false, reason: "secret" }
  const matched = signatures
    .split(" ")
    .filter((entry) => entry.startsWith("v1,"))
    .some((entry) => constantTimeEqual(entry.slice(3), expected))
  return matched ? { ok: true, messageId: id } : { ok: false, reason: "signature" }
}
