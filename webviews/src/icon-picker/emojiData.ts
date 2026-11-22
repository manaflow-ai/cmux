// The bundled emoji table (generated/emoji-data.json, Unicode emoji-test.txt + CLDR annotations,
// Unicode License v3; scripts/icon-picker/gen-emoji-data.mjs) decoded into records. Search text
// is built lazily (warmSearch), so page load decodes only the rows.

export type EmojiGroupID =
  | "smileys-emotion"
  | "people-body"
  | "animals-nature"
  | "food-drink"
  | "travel-places"
  | "activities"
  | "objects"
  | "symbols"
  | "flags";

export type SkinTone = 0 | 1 | 2 | 3 | 4 | 5;

/**
 * One emoji. The folded search text is built on first use (`warmSearch` builds every record's
 * after the first frame), so decoding the table at page load stays a few milliseconds.
 */
export class EmojiRecord {
  private text?: { name: string; search: string };

  constructor(
    /** Position in the table: the default order, and the stable id for recents. */
    readonly index: number,
    readonly emoji: string,
    readonly group: EmojiGroupID,
    /** Emoji version times 10 (15.1 -> 151). */
    readonly version: number,
    readonly names: { readonly en: string; readonly ja: string },
    private readonly keywords: string,
    /** GitHub shortcodes without colons, the shown one first ("tada"); may be empty. */
    readonly shortcodes: readonly string[],
    /** The five uniform skin-tone forms, light to dark, when the emoji takes a tone. */
    readonly tones?: readonly string[],
  ) {}

  /** Folded names (search.ts), each prefixed with "\n" so a prefix match is `\n<query>`. */
  get nameText(): string {
    return this.build().name;
  }

  /** Folded names and keywords, every word prefixed with "\n". */
  get searchText(): string {
    return this.build().search;
  }

  private build() {
    if (this.text) return this.text;
    const names = [fold(this.names.en), fold(this.names.ja)];
    const all = new Set([...names, ...words(this.names.en), ...words(this.names.ja)]);
    for (const code of this.shortcodes) all.add(fold(code));
    for (const keyword of this.keywords.split("|")) {
      if (!keyword) continue;
      all.add(fold(keyword));
      for (const word of words(keyword)) all.add(word);
    }
    this.text = { name: `\n${names.join("\n")}`, search: `\n${[...all].join("\n")}` };
    return this.text;
  }
}

export interface EmojiTable {
  readonly unicode: { readonly emoji: string; readonly cldr: string; readonly shortcodes?: string };
  readonly groups: readonly EmojiGroupID[];
  readonly records: readonly EmojiRecord[];
}

type Row = [string, number, number, string, string, string, string, string, string[]?];

export interface RawEmojiTable {
  unicode: { emoji: string; cldr: string; shortcodes?: string };
  groups: string[];
  rows: Row[];
}

/** Case, width and kana folding: NFKC, lower case, katakana to hiragana, no long-vowel mark gaps. */
export function fold(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[ァ-ヶ]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0x60));
}

function words(text: string): string[] {
  return fold(text)
    .split(/[\s|:,.!?()'"“”・、。_-]+/u)
    .filter(Boolean);
}

export function decodeEmojiTable(raw: RawEmojiTable): EmojiTable {
  const groups = raw.groups as EmojiGroupID[];
  const records = raw.rows.map(
    ([emoji, group, version, nameEn, keywordsEn, nameJa, keywordsJa, codes, tones], index) =>
      new EmojiRecord(
        index,
        emoji,
        groups[group],
        version,
        { en: nameEn, ja: nameJa },
        `${keywordsEn}|${keywordsJa}`,
        codes ? codes.split("|") : [],
        tones,
      ),
  );
  return { unicode: raw.unicode, groups, records };
}

/** Builds every record's search text now (call when idle, after the first frame). */
export function warmSearch(table: EmojiTable): void {
  for (const record of table.records) void record.searchText;
}

/** The emoji in the chosen tone; the base form when it takes no tone or the tone is 0. */
export function withTone(record: EmojiRecord, tone: SkinTone): string {
  return tone > 0 && record.tones ? record.tones[tone - 1] : record.emoji;
}
