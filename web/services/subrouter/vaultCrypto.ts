import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

// AES-256-GCM envelope for Subrouter credential payloads.
//
// The threat this addresses is a database dump: OAuth refresh chains are the
// long-lived secret, and losing them means re-running interactive login for
// every account. Encrypting at rest means a dump alone is not enough.
//
// The key lives in SR_VAULT_KEY (base64, 32 bytes) rather than in the database,
// so the key and the ciphertext never share a compromise boundary.

const KEY_BYTES = 32;
const NONCE_BYTES = 12;
export const CURRENT_KEY_VERSION = 1;

export type SealedSecret = {
  ciphertext: string;
  nonce: string;
  keyVersion: number;
};

export class VaultKeyMissingError extends Error {
  constructor() {
    super("SR_VAULT_KEY is not configured; refusing to handle Subrouter credentials");
    this.name = "VaultKeyMissingError";
  }
}

export function isVaultConfigured(): boolean {
  return resolveKeyOrNull() !== null;
}

function resolveKeyOrNull(): Buffer | null {
  const raw = process.env.SR_VAULT_KEY?.trim();
  if (!raw) return null;
  let key: Buffer;
  try {
    key = Buffer.from(raw, "base64");
  } catch {
    return null;
  }
  return key.length === KEY_BYTES ? key : null;
}

function resolveKey(): Buffer {
  const key = resolveKeyOrNull();
  if (!key) throw new VaultKeyMissingError();
  return key;
}

// seal encrypts a credential payload. The GCM auth tag is appended to the
// ciphertext so tampering is detected on open rather than silently decrypting.
export function seal(plaintext: string): SealedSecret {
  const key = resolveKey();
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    ciphertext: Buffer.concat([encrypted, tag]).toString("base64"),
    nonce: nonce.toString("base64"),
    keyVersion: CURRENT_KEY_VERSION,
  };
}

export function open(sealed: SealedSecret): string {
  const key = resolveKey();
  const raw = Buffer.from(sealed.ciphertext, "base64");
  if (raw.length < 17) {
    throw new Error("ciphertext too short to contain an auth tag");
  }
  const tag = raw.subarray(raw.length - 16);
  const body = raw.subarray(0, raw.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(sealed.nonce, "base64"));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8");
}

// hashDeviceCode stores only a digest of the CLI-held device code, so a database
// dump cannot be replayed to complete a pending login.
export function hashDeviceCode(deviceCode: string): string {
  return createHash("sha256").update(deviceCode, "utf8").digest("base64");
}

// Ambiguous characters (0/O, 1/I/L) are excluded: this code gets read aloud and
// retyped by a human.
const USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function generateUserCode(): string {
  const bytes = randomBytes(8);
  let out = "";
  for (let i = 0; i < 8; i += 1) {
    if (i === 4) out += "-";
    out += USER_CODE_ALPHABET[bytes[i]! % USER_CODE_ALPHABET.length];
  }
  return out;
}

export function generateDeviceCode(): string {
  return randomBytes(32).toString("base64url");
}
