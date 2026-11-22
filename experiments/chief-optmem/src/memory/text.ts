/** Text rules shared with the reference: UTF-8 byte lengths and Python's notion of whitespace. */

const encoder = new TextEncoder();

export const utf8Length = (s: string) => encoder.encode(s).length;

/** Characters Python's str.strip() removes (str.isspace), which differ from String.prototype.trim. */
const PY_SPACE = String.fromCodePoint(
  0x09,
  0x0a,
  0x0b,
  0x0c,
  0x0d,
  0x1c,
  0x1d,
  0x1e,
  0x1f,
  0x20,
  0x85,
  0xa0,
  0x1680,
  ...Array.from({ length: 11 }, (_, i) => 0x2000 + i),
  0x2028,
  0x2029,
  0x202f,
  0x205f,
  0x3000,
);

export function pyStrip(s: string): string {
  let a = 0;
  let b = s.length;
  while (a < b && PY_SPACE.includes(s[a]!)) a++;
  while (b > a && PY_SPACE.includes(s[b - 1]!)) b--;
  return s.slice(a, b);
}

/** "1 memory", "2 memories", "3 matches": the reference's English plurals. */
export function plural(n: number, word: string): string {
  if (n === 1) return `1 ${word}`;
  let w = word;
  if (w.endsWith("y")) w = `${w.slice(0, -1)}ie`;
  else if (w.endsWith("s") || w.endsWith("h") || w.endsWith("x")) w += "e";
  return `${n} ${w}s`;
}

/** A real calendar date in YYYY-MM-DD form. */
export function isRealDate(s: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (y < 1 || mo < 1 || mo > 12 || d < 1) return false;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]!;
  return d <= days;
}
