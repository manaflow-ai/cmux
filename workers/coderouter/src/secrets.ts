const encoder = new TextEncoder();
const decoder = new TextDecoder();

export async function decryptEnvelopeSecret(envelope: string, masterKeyBase64: string | undefined): Promise<string | null> {
  if (!masterKeyBase64 || !envelope.startsWith("crv1:")) return null;
  const [, ivPart, ciphertextPart] = envelope.split(":");
  if (!ivPart || !ciphertextPart) return null;
  const iv = fromBase64Url(ivPart);
  const ciphertext = fromBase64Url(ciphertextPart);
  const keyBytes = fromBase64(masterKeyBase64);
  if (!iv || !ciphertext || !keyBytes || keyBytes.byteLength !== 32) return null;
  try {
    const key = await crypto.subtle.importKey("raw", toArrayBuffer(keyBytes), "AES-GCM", false, ["decrypt"]);
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: toArrayBuffer(iv) }, key, toArrayBuffer(ciphertext));
    return decoder.decode(plaintext);
  } catch {
    return null;
  }
}

export async function encryptEnvelopeForTests(plaintext: string, masterKeyBase64: string, iv: Uint8Array): Promise<string> {
  const keyBytes = fromBase64(masterKeyBase64);
  if (!keyBytes || keyBytes.byteLength !== 32) throw new Error("invalid key");
  const key = await crypto.subtle.importKey("raw", toArrayBuffer(keyBytes), "AES-GCM", false, ["encrypt"]);
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: toArrayBuffer(iv) }, key, encoder.encode(plaintext));
  return `crv1:${toBase64Url(iv)}:${toBase64Url(new Uint8Array(ciphertext))}`;
}

function fromBase64(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

function fromBase64Url(value: string): Uint8Array | null {
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    return fromBase64(padded);
  } catch {
    return null;
  }
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
