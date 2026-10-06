// Canonical CIDR parsing, copied from main's services/vms/networkPolicy.ts (not on this branch).

export class CidrValidationError extends Error {
  constructor(readonly path: string, message: string) {
    super(`${path}: ${message}`);
    this.name = "CidrValidationError";
  }
}

/** Canonical CIDR, or throws. Accepts a bare address (→ /32 or /128). */
export function canonicalCidr(input: string, path = "cidr"): string {
  const raw = input.trim();
  const [address, prefixText, extra] = raw.split("/");
  if (extra !== undefined || !address) throw new CidrValidationError(path, `${JSON.stringify(input)} is not an IP range`);
  const v4 = parseIpv4(address);
  if (v4 !== null) {
    const prefix = prefixText === undefined ? 32 : parsePrefix(prefixText, 32, path);
    const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
    const network = (v4 & mask) >>> 0;
    return `${[24, 16, 8, 0].map((s) => (network >>> s) & 255).join(".")}/${prefix}`;
  }
  const v6 = parseIpv6(address);
  if (v6) {
    const prefix = prefixText === undefined ? 128 : parsePrefix(prefixText, 128, path);
    const masked = v6.map((word, i) => {
      const bits = Math.max(0, Math.min(16, prefix - i * 16));
      return bits === 0 ? 0 : word & ((0xffff << (16 - bits)) & 0xffff);
    });
    return `${formatIpv6(masked)}/${prefix}`;
  }
  throw new CidrValidationError(path, `${JSON.stringify(input)} is not an IPv4 or IPv6 address`);
}

function parsePrefix(text: string, max: number, path: string): number {
  if (!/^\d{1,3}$/.test(text)) throw new CidrValidationError(path, `prefix ${JSON.stringify(text)} is not a number`);
  const prefix = Number(text);
  if (prefix > max) throw new CidrValidationError(path, `prefix /${prefix} is longer than /${max}`);
  return prefix;
}

function parseIpv4(text: string): number | null {
  const parts = text.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255 || (part.length > 1 && part.startsWith("0")))) {
    return null;
  }
  return parts.reduce((acc, part) => ((acc << 8) | Number(part)) >>> 0, 0);
}

function parseIpv6(text: string): number[] | null {
  if (!/^[0-9a-fA-F:]+$/.test(text) || text.split("::").length > 2) return null;
  const [head, tail] = text.includes("::") ? text.split("::") : [text, undefined];
  const parse = (part: string) => (part === "" ? [] : part.split(":"));
  const headWords = parse(head);
  const tailWords = tail === undefined ? [] : parse(tail);
  const missing = 8 - headWords.length - tailWords.length;
  if (tail === undefined ? missing !== 0 : missing < 1) return null;
  const words = [...headWords, ...Array<string>(tail === undefined ? 0 : missing).fill("0"), ...tailWords];
  if (words.some((word) => !/^[0-9a-fA-F]{1,4}$/.test(word))) return null;
  return words.map((word) => parseInt(word, 16));
}

function formatIpv6(words: number[]): string {
  // RFC 5952: compress the longest run (length ≥ 2) of zero words.
  let bestStart = -1;
  let bestLength = 0;
  for (let i = 0; i < 8;) {
    if (words[i] !== 0) { i += 1; continue; }
    let j = i;
    while (j < 8 && words[j] === 0) j += 1;
    if (j - i > bestLength && j - i >= 2) { bestStart = i; bestLength = j - i; }
    i = j;
  }
  const hex = words.map((word) => word.toString(16));
  if (bestStart < 0) return hex.join(":");
  return `${hex.slice(0, bestStart).join(":")}::${hex.slice(bestStart + bestLength).join(":")}`;
}
