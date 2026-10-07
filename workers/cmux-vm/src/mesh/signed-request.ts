/**
 * Install-key signatures (mesh M2, cx-0op.4; device-signed requests M3,
 * cx-0op.5; DESIGN.md sections 3 and 5).
 *
 * A device holds an ECDSA P-256 install key that never leaves it. Enroll, key
 * rotation and the device's own reads carry a signature by that key over this
 * message (UTF-8, lines joined by "\n", no trailing newline):
 *
 *   cmux-mesh-v1
 *   <purpose: enroll | rotate-key | peers | tunnel>
 *   <target: the mesh id for enroll, the device id for the others>
 *   <the WireGuard public key being registered: the device key on enroll, the
 *    new key on rotate-key, empty for peers and tunnel>
 *   <installPublicKey>
 *   <the device name for enroll, empty for the others>
 *   <signedAt: unix milliseconds>
 *   <nonce: 16 random bytes, base64url without padding>
 *
 * For a device without a credential (enrolled with a one-time code) the
 * signature IS the credential on the routes under /v1/devices/{id}/signed/:
 * peers, tunnel and rotate-key of that one device, nothing else.
 *
 * The Worker rebuilds the message from the request, so a changed field fails
 * the signature. signedAt must be within SIGNATURE_SKEW_MS of the Worker's
 * clock, and the SHA-256 of an accepted message is stored until it could no
 * longer be fresh: the same message is never accepted twice. ECDSA signatures
 * can be re-encoded by anyone (s and n - s both verify), so replay is keyed by
 * the message, never by the signature bytes.
 */
import { Effect, Schema } from "effect";

/** Accepted distance between signedAt and the Worker's clock. */
export const SIGNATURE_SKEW_MS = 120_000;

export const SIGNED_MESSAGE_VERSION = "cmux-mesh-v1";

export type SignedPurpose = "enroll" | "rotate-key" | "peers" | "tunnel";

/** The 65-byte uncompressed P-256 point, base64 (starts with 0x04, so with "B"). */
export const InstallPublicKey = Schema.String.pipe(Schema.pattern(/^B[A-Za-z0-9+/]{86}=$/u)).annotations({
  description: "The device's install public key: ECDSA P-256, the 65-byte uncompressed point, base64. The private key never leaves the device.",
});

export const SignedAt = Schema.Int.pipe(Schema.positive()).annotations({ description: "When the device signed, in unix milliseconds; accepted within 120 s of the server's clock." });

export const Nonce = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9_-]{22}$/u)).annotations({ description: "16 random bytes, base64url without padding." });

/** 64-byte r||s, base64. */
export const Signature = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9+/]{86}==$/u)).annotations({
  description: "ECDSA P-256 SHA-256 signature (64-byte r||s, base64) by the install key over the cmux-mesh-v1 message.",
});

export interface SignedFields {
  readonly purpose: SignedPurpose;
  readonly target: string;
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
  readonly name: string;
  readonly signedAt: number;
  readonly nonce: string;
}

export const signedMessage = (fields: SignedFields): string =>
  [SIGNED_MESSAGE_VERSION, fields.purpose, fields.target, fields.wgPublicKey, fields.installPublicKey, fields.name, String(fields.signedAt), fields.nonce].join("\n");

const fromBase64 = (text: string): Uint8Array<ArrayBuffer> | null => {
  try {
    const binary = atob(text);
    const bytes = new Uint8Array(new ArrayBuffer(binary.length));
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
};

const hex = (bytes: ArrayBuffer): string => Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");

export type SignatureCheck =
  | { readonly ok: true; readonly messageSha256: string; readonly expiresAt: Date }
  | { readonly ok: false; readonly reason: "stale" | "invalid" };

/**
 * Checks the signature, then freshness. Never fails: a malformed key or
 * signature is "invalid". The signature is checked first so that "stale" is
 * only ever said to the holder of the install key: on the credential-free
 * device routes a forged request learns nothing. The caller still has to
 * claim `messageSha256` (replay) before it acts.
 */
export const checkSignature = (fields: SignedFields, signature: string, nowMs: number): Effect.Effect<SignatureCheck> =>
  Effect.promise(async (): Promise<SignatureCheck> => {
    const point = fromBase64(fields.installPublicKey);
    const raw = fromBase64(signature);
    if (point === null || point.length !== 65 || point[0] !== 4 || raw === null || raw.length !== 64) return { ok: false, reason: "invalid" };
    const message = new TextEncoder().encode(signedMessage(fields));
    try {
      const key = await crypto.subtle.importKey("raw", point, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
      const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, message);
      if (!valid) return { ok: false, reason: "invalid" };
    } catch {
      return { ok: false, reason: "invalid" };
    }
    if (Math.abs(nowMs - fields.signedAt) > SIGNATURE_SKEW_MS) return { ok: false, reason: "stale" };
    return {
      ok: true,
      messageSha256: hex(await crypto.subtle.digest("SHA-256", message)),
      expiresAt: new Date(fields.signedAt + SIGNATURE_SKEW_MS),
    };
  });

/** SHA-256 hex of a string (enrollment codes are stored this way). */
export const sha256Hex = (text: string): Effect.Effect<string> =>
  Effect.promise(async () => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))));
