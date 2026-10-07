// Pseudo-locales, built from the English table so every string a page reads changes:
//   en-XA: accented letters and about 40% more length, in brackets, so clipped, concatenated or
//          hard-coded text shows at a glance;
//   ar-XB: the English text in right-to-left marks, under an RTL document (the page's own
//          languageDirection picks `rtl` for an `ar` tag), for mirroring checks.
// Placeholders ({name}, %@, %1$@, %%) are kept as they are, so formatting still works.

const ACCENTS: Record<string, string> = {
  a: "á",
  b: "ƀ",
  c: "ç",
  d: "ð",
  e: "é",
  f: "ƒ",
  g: "ĝ",
  h: "ĥ",
  i: "í",
  j: "ĵ",
  k: "ķ",
  l: "ļ",
  m: "ɱ",
  n: "ñ",
  o: "ó",
  p: "þ",
  q: "ǫ",
  r: "ŕ",
  s: "š",
  t: "ţ",
  u: "ú",
  v: "ṽ",
  w: "ŵ",
  x: "ẋ",
  y: "ý",
  z: "ž",
  A: "Å",
  B: "Ɓ",
  C: "Ç",
  D: "Ð",
  E: "É",
  F: "Ƒ",
  G: "Ĝ",
  H: "Ĥ",
  I: "Î",
  J: "Ĵ",
  K: "Ķ",
  L: "Ļ",
  M: "Ṁ",
  N: "Ñ",
  O: "Ö",
  P: "Þ",
  Q: "Ǫ",
  R: "Ŕ",
  S: "Š",
  T: "Ţ",
  U: "Û",
  V: "Ṽ",
  W: "Ŵ",
  X: "Ẋ",
  Y: "Ý",
  Z: "Ž",
};

/** `{name}`, `%@`, `%1$@`, `%d`, `%%`: kept verbatim. */
const PLACEHOLDER = /(\{\w+\}|%(?:\d+\$)?[@dsf]|%%)/;

const RLE = "‫";
const PDF = "‬";

export function pseudoText(text: string, locale: "en-XA" | "ar-XB"): string {
  if (!text) return text;
  if (locale === "ar-XB") return `${RLE}${text}${PDF}`;
  const parts = text.split(PLACEHOLDER);
  const body = parts
    .map((part, index) => (index % 2 ? part : part.replace(/[A-Za-z]/g, (letter) => ACCENTS[letter] ?? letter)))
    .join("");
  const letters = text.replace(/\{\w+\}|%(?:\d+\$)?[@dsf]|%%|\s/g, "").length;
  const padding = "·".repeat(Math.max(1, Math.round(letters * 0.4)));
  return `[${body} ${padding}]`;
}

/** Adds the pseudo-locale tables to a `{locale: {key: text}}` table, from its English. */
export function addPseudoLocales(table: Record<string, Record<string, string>>): void {
  const english = table.en;
  if (!english) return;
  for (const locale of ["en-XA", "ar-XB"] as const) {
    if (table[locale]) continue;
    table[locale] = Object.fromEntries(Object.entries(english).map(([key, text]) => [key, pseudoText(text, locale)]));
  }
}

export const isPseudo = (locale: string): locale is "en-XA" | "ar-XB" => locale === "en-XA" || locale === "ar-XB";
