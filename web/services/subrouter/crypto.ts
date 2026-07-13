import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
} from "node:crypto";

const CIPHER = "aes-256-gcm";
const VERSION = "v1";
const IV_BYTES = 12;
const KEY_BYTES = 32;

export class SubrouterTenantKeySecretError extends Error {
  constructor(message = "subrouter tenant key secret is invalid") {
    super(message);
    this.name = "SubrouterTenantKeySecretError";
  }
}

export class SubrouterTenantKeyDecryptionError extends Error {
  constructor(message = "subrouter tenant key could not be decrypted") {
    super(message);
    this.name = "SubrouterTenantKeyDecryptionError";
  }
}

export function encryptTenantKey(
  tenantKey: string,
  secret = process.env.SUBROUTER_TENANT_KEY_SECRET,
): string {
  const key = decodeTenantKeySecret(secret);
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(CIPHER, key, iv);
  const ciphertext = Buffer.concat([
    cipher.update(tenantKey, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  return [
    VERSION,
    iv.toString("base64"),
    tag.toString("base64"),
    ciphertext.toString("base64"),
  ].join(":");
}

export function decryptTenantKey(
  encryptedTenantKey: string,
  secret = process.env.SUBROUTER_TENANT_KEY_SECRET,
): string {
  const key = decodeTenantKeySecret(secret);
  const parts = encryptedTenantKey.split(":");
  if (parts.length !== 4 || parts[0] !== VERSION) {
    throw new SubrouterTenantKeyDecryptionError();
  }

  try {
    const iv = Buffer.from(parts[1], "base64");
    const tag = Buffer.from(parts[2], "base64");
    const ciphertext = Buffer.from(parts[3], "base64");
    if (iv.length !== IV_BYTES || tag.length !== 16 || ciphertext.length === 0) {
      throw new SubrouterTenantKeyDecryptionError();
    }

    const decipher = createDecipheriv(CIPHER, key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ]).toString("utf8");
  } catch (err) {
    if (err instanceof SubrouterTenantKeyDecryptionError) throw err;
    throw new SubrouterTenantKeyDecryptionError();
  }
}

function decodeTenantKeySecret(secret: string | undefined): Buffer {
  const normalized = secret?.trim().replace(/\s+/g, "");
  if (!normalized) {
    throw new SubrouterTenantKeySecretError();
  }
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(normalized)) {
    throw new SubrouterTenantKeySecretError();
  }

  const decoded = Buffer.from(normalized, "base64");
  if (decoded.length !== KEY_BYTES || decoded.toString("base64") !== normalized) {
    throw new SubrouterTenantKeySecretError();
  }
  return decoded;
}
