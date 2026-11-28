// Text rules the TypeScript and Rust cores share exactly (cmux-chief acp.rs
// and rules.rs mirror them; the corpus checks them).

/** A JSON value with undefined fields dropped (what the wire carries). */
export const plain = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

/** Code point order, which is UTF-8 byte order: the Rust core's BTreeMap<String> order. */
export function compareCodePoints(a: string, b: string): number {
  const length = Math.min(a.length, b.length);
  for (let i = 0; i < length; i++) {
    const x = a.codePointAt(i)!;
    const y = b.codePointAt(i)!;
    if (x !== y) return x < y ? -1 : 1;
    if (x > 0xffff) i++;
  }
  return a.length - b.length;
}

/**
 * Compact JSON with object keys sorted in code point order: the text Rust's
 * `serde_json::Value::to_string` writes (serde_json keeps object keys sorted).
 * Numbers are JavaScript's; an integer-valued float parsed from `1.0` is
 * written `1`, where serde_json writes `1.0`, so the corpus uses integers.
 */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map((item) => (item === undefined ? "null" : canonicalJson(item))).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record)
      .filter((key) => record[key] !== undefined)
      .sort(compareCodePoints);
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}
