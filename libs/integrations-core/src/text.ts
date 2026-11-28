// Small text helpers shared by the cmux modules of this package. cmux code (no
// upstream code). No host globals (no TextEncoder, no crypto), so the helpers
// run in Workers, Bun, Node and the QuickJS and JavaScriptCore app engines.

/** 32-bit FNV-1a in 8 hex digits: a stable, cheap fingerprint (not a security hash). */
export const fnv1a = (text: string): string => {
  let h = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16).padStart(8, "0")
}

/** UTF-8 byte length of a string without TextEncoder (a lone surrogate counts as 3 bytes, as TextEncoder writes U+FFFD). */
export const utf8Length = (text: string): number => {
  let n = 0
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length && (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
      n += 4
      i++
    } else n += 3
  }
  return n
}

/** Code-point order (localeCompare differs between JavaScriptCore and QuickJS). */
export const compareCodePoints = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)
