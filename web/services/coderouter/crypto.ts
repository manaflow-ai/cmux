import { CoderouterConfigurationError } from "./errors";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const ENVELOPE_PREFIX = "crv1";

function toBase64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function fromBase64Url(value: string): Uint8Array {
  return new Uint8Array(Buffer.from(value, "base64url"));
}

export async function encryptSecret(plaintext: string, masterKey = process.env.CODEROUTER_MASTER_KEY): Promise<string> {
  const key = await importAesKey(masterKey);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: arrayBufferFromBytes(iv) },
    key,
    encoder.encode(plaintext),
  );
  return `${ENVELOPE_PREFIX}:${toBase64Url(iv)}:${toBase64Url(new Uint8Array(ciphertext))}`;
}

export async function decryptSecret(envelope: string, masterKey = process.env.CODEROUTER_MASTER_KEY): Promise<string> {
  const parts = envelope.split(":");
  if (parts.length !== 3 || parts[0] !== ENVELOPE_PREFIX) {
    throw new CoderouterConfigurationError("decryptSecret", "Invalid coderouter secret envelope.");
  }
  const key = await importAesKey(masterKey);
  const iv = fromBase64Url(parts[1] ?? "");
  const ciphertext = fromBase64Url(parts[2] ?? "");
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: arrayBufferFromBytes(iv) },
    key,
    arrayBufferFromBytes(ciphertext),
  );
  return decoder.decode(plaintext);
}

async function importAesKey(masterKey: string | undefined): Promise<CryptoKey> {
  const raw = masterKey?.trim();
  if (!raw) {
    throw new CoderouterConfigurationError("coderouterMasterKey", "CODEROUTER_MASTER_KEY is not configured.");
  }
  const bytes = fromBase64Url(raw);
  if (bytes.byteLength !== 32) {
    throw new CoderouterConfigurationError("coderouterMasterKey", "CODEROUTER_MASTER_KEY must be 32 base64 bytes.");
  }
  return crypto.subtle.importKey("raw", arrayBufferFromBytes(bytes), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

function arrayBufferFromBytes(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
