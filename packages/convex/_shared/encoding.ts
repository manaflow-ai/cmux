export function base64urlToBytes(s: string): Uint8Array {
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let buffer = 0;
  let bits = 0;
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const val = abc.indexOf(s[i]!);
    if (val === -1) continue;
    buffer = (buffer << 6) | val;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

export function base64urlFromBytes(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
    out += abc[x & 63];
  }
  if (i + 1 === bytes.length) {
    const x = bytes[i] << 16;
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
  } else if (i < bytes.length) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
  }
  return out;
}

export function bytesToHex(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function base64FromBytes(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let out = "";
  let i = 0;

  for (; i + 2 < bytes.length; i += 3) {
    const x = (bytes[i]! << 16) | (bytes[i + 1]! << 8) | bytes[i + 2]!;
    out += BASE64_ALPHABET[(x >> 18) & 63]!;
    out += BASE64_ALPHABET[(x >> 12) & 63]!;
    out += BASE64_ALPHABET[(x >> 6) & 63]!;
    out += BASE64_ALPHABET[x & 63]!;
  }

  const remaining = bytes.length - i;
  if (remaining === 1) {
    const x = bytes[i]! << 16;
    out += BASE64_ALPHABET[(x >> 18) & 63]!;
    out += BASE64_ALPHABET[(x >> 12) & 63]!;
    out += "==";
  } else if (remaining === 2) {
    const x = (bytes[i]! << 16) | (bytes[i + 1]! << 8);
    out += BASE64_ALPHABET[(x >> 18) & 63]!;
    out += BASE64_ALPHABET[(x >> 12) & 63]!;
    out += BASE64_ALPHABET[(x >> 6) & 63]!;
    out += "=";
  }

  return out;
}

export function stringToBase64(value: string): string {
  const bytes = new TextEncoder().encode(value);
  return base64FromBytes(bytes);
}
