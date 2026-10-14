// Canonical endpoint-id handling for the account control plane.
//
// An iroh endpoint id names a 32-byte Ed25519 public key. The relay parses
// the wire forms with EndpointId::from_str, which accepts EXACTLY 64-char hex
// or 52-char RFC 4648 base32 (both case-insensitive; to_string() emits
// lowercase hex) and treats them as the SAME key — see the matching grammar in
// web/services/relay/token.ts. Any two spellings of one key must therefore
// collapse to one canonical form BEFORE any trust decision: revocation
// checks, device-overlay keys, socket ownership, generation counters,
// credential minting, hint fan-out, and directory joins all key on the
// canonical form, never on the spelling a client happened to send.
//
// Canonical form: trimmed, lowercase, 64-char hex. Everything else — wrong
// length, padding characters, non-canonical base32 trailing bits, or any
// other string — is rejected with null so no alternate spelling survives
// past this boundary. The accepted set deliberately equals what the relay
// parses: never widen it (z-base-32 is a separate iroh API the relay does
// not use, so it is NOT accepted here either).

const HEX_ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;

// A 52-char RFC 4648 base32 encoding of exactly 32 bytes carries 4 trailing
// zero bits, so the final symbol can only be `a` (0) or `q` (16); any other
// final symbol is a non-canonical encoding that iroh's BASE32_NOPAD decoder
// rejects (mirrors web/services/relay/token.ts).
const BASE32_ENDPOINT_ID_RE = /^[a-z2-7]{51}[aq]$/;

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

/** Collapse one accepted spelling of an iroh endpoint id to the canonical
 * trimmed-lowercase-64-hex form, or null when the input is not an endpoint
 * id at all. Idempotent: canonical input returns itself. */
export function canonicalEndpointId(endpointId: string): string | null {
  const value = endpointId.trim().toLowerCase();
  if (HEX_ENDPOINT_ID_RE.test(value)) return value;
  if (BASE32_ENDPOINT_ID_RE.test(value)) return base32ToHex(value);
  return null;
}

/** Decode canonical RFC 4648 base32 (no padding) of exactly 32 bytes to
 * lowercase hex. Null on non-zero trailing bits (non-canonical encoding),
 * though the caller's regex already excludes those final symbols. */
function base32ToHex(value: string): string | null {
  let accumulator = 0;
  let bits = 0;
  let hex = "";
  for (const char of value) {
    const index = BASE32_ALPHABET.indexOf(char);
    if (index < 0) return null; // unreachable behind the regex; fail closed
    accumulator = (accumulator << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      hex += ((accumulator >> bits) & 0xff).toString(16).padStart(2, "0");
    }
  }
  if (hex.length !== 64) return null;
  if ((accumulator & ((1 << bits) - 1)) !== 0) return null;
  return hex;
}
