// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover). Typing `:` and two letters at a word start lists
// the emoji whose GitHub shortcode matches; a text emoticon (`:)`, `:DD`, `<3`) lists the face it
// stands for. Picking one writes the glyph over what was typed (Composer.tsx, EmojiMenu.tsx).
//
// The table is the icon picker's (icon-picker/generated/emoji-data.json: Unicode emoji-test.txt and
// CLDR annotations, Unicode License v3; emojibase-data GitHub shortcodes, MIT). It loads in its own
// chunk after the composer's first paint (`loadEmojiShortcodes`), never with the page.
import { decodeEmojiTable, warmSearch, type EmojiRecord, type RawEmojiTable } from "../../icon-picker/emojiData";
import { decodePrefs, recordUse, searchBoost, type PickerPrefs } from "../../icon-picker/recents";

/// How many rows the menu lists at most.
export const EMOJI_SHOWN = 6;
/// Letters after `:` before the menu opens (one letter matches half the table).
export const EMOJI_MIN_QUERY = 2;

export interface EmojiShortcodes {
  readonly records: readonly EmojiRecord[];
  /** Every shortcode (primary and alias) to its record. */
  readonly byCode: ReadonlyMap<string, EmojiRecord>;
  /** A glyph to its table index (recents are kept by glyph). */
  readonly byEmoji: ReadonlyMap<string, number>;
}

/// What the caret ends: a `:shortcode` being typed, or a whole text emoticon.
export interface EmojiTrigger {
  /** Where the typed token starts in the markdown. */
  readonly start: number;
  /** The token as shown (`:tedd`, `:DD`, `<3`), markdown escapes undone. */
  readonly token: string;
  /** The shortcode letters after `:`, lower case; undefined for an emoticon that is not one. */
  readonly query?: string;
  /** The token is a text emoticon: the menu opens with no row chosen, so Return still sends. */
  readonly emoticon: boolean;
}

/// Text emoticons and the shortcodes they mean, best first. Case matters (`:P` and `:p` both listed).
export const EMOTICONS: Readonly<Record<string, readonly string[]>> = {
  ":)": ["slightly_smiling_face", "smiley", "blush"],
  ":-)": ["slightly_smiling_face", "smiley", "blush"],
  "(:": ["slightly_smiling_face", "smiley"],
  ":(": ["slightly_frowning_face", "disappointed", "cry"],
  ":-(": ["slightly_frowning_face", "disappointed", "cry"],
  ":D": ["smiley", "smile", "grin"],
  ":-D": ["smiley", "smile", "grin"],
  ":DD": ["laughing", "joy", "rofl"],
  ":DDD": ["joy", "rofl", "laughing"],
  XD: ["laughing", "joy", "rofl"],
  xD: ["laughing", "joy", "rofl"],
  ";)": ["wink", "stuck_out_tongue_winking_eye"],
  ";-)": ["wink", "stuck_out_tongue_winking_eye"],
  ":P": ["stuck_out_tongue", "stuck_out_tongue_winking_eye", "stuck_out_tongue_closed_eyes"],
  ":p": ["stuck_out_tongue", "stuck_out_tongue_winking_eye", "stuck_out_tongue_closed_eyes"],
  ":-P": ["stuck_out_tongue", "stuck_out_tongue_winking_eye"],
  ";P": ["stuck_out_tongue_winking_eye", "stuck_out_tongue"],
  ";p": ["stuck_out_tongue_winking_eye", "stuck_out_tongue"],
  ":O": ["open_mouth", "astonished"],
  ":o": ["open_mouth", "astonished"],
  ":'(": ["cry", "sob"],
  ":|": ["neutral_face", "expressionless"],
  ":/": ["confused"],
  ":*": ["kissing_heart"],
  "<3": ["heart", "sparkling_heart", "two_hearts"],
  "</3": ["broken_heart"],
  "B)": ["sunglasses"],
  "8)": ["sunglasses"],
  ">:(": ["angry", "rage"],
  "^^": ["blush", "smile"],
  "^_^": ["blush", "smile"],
  "-_-": ["expressionless"],
};

let table: Promise<EmojiShortcodes> | undefined;

/// The table, once per page, in its own chunk. A failed load is tried again on the next call.
export function loadEmojiShortcodes(): Promise<EmojiShortcodes> {
  table ??= import("../../icon-picker/generated/emoji-data.json")
    .then((module) => {
      const decoded = decodeEmojiTable((module.default ?? module) as unknown as RawEmojiTable);
      // Names and keywords are folded now, at idle, not on the first keystroke that needs them.
      warmSearch(decoded);
      return indexEmoji(decoded.records);
    })
    .catch((error: unknown) => {
      table = undefined;
      throw error;
    });
  return table;
}

export function indexEmoji(records: readonly EmojiRecord[]): EmojiShortcodes {
  const byCode = new Map<string, EmojiRecord>();
  const byEmoji = new Map<string, number>();
  for (const record of records) {
    byEmoji.set(record.emoji, record.index);
    for (const code of record.shortcodes) if (!byCode.has(code)) byCode.set(code, record);
  }
  return { records, byCode, byEmoji };
}

const SPACE = /(?:^|\s|&#x20;|&#32;|&nbsp;)((?:\\.|&[a-z]+;|&#x?[0-9a-f]+;|[^\s\\&]|&(?![a-z#]))+)$/i;

function unescape(raw: string): string {
  return raw
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&amp;/gi, "&")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/\\(.)/g, "$1");
}

/// True when `at` in `markdown` is inside a code span or a fenced code block.
function inCode(markdown: string, at: number): boolean {
  const before = markdown.slice(0, at);
  const fences = before.match(/^\s{0,3}(```|~~~)/gm)?.length ?? 0;
  if (fences % 2 === 1) return true;
  const line = before.slice(before.lastIndexOf("\n") + 1);
  return (line.match(/`/g)?.length ?? 0) % 2 === 1;
}

/// The emoji token the caret ends in the prompt's markdown, or undefined. A token starts a word, so
/// a time (`10:30`), a URL (`https://`) or `key:value` never opens the menu; neither does code.
export function emojiTrigger(markdown: string, at: number): EmojiTrigger | undefined {
  const before = markdown.slice(0, at);
  const found = SPACE.exec(before);
  if (!found) return undefined;
  const raw = found[1]!;
  const start = before.length - raw.length;
  const token = unescape(raw);
  const emoticon = Object.hasOwn(EMOTICONS, token);
  const code = /^:([a-z0-9_+-]+)$/i.exec(token)?.[1];
  const query = code && code.length >= EMOJI_MIN_QUERY ? code.toLowerCase() : undefined;
  if (!emoticon && !query) return undefined;
  if (inCode(markdown, start)) return undefined;
  return { start, token, query, emoticon };
}

export interface EmojiMatch {
  readonly key: string;
  readonly emoji: string;
  /** The shortcode shown, without colons: the one that matched. */
  readonly code: string;
  /** How many leading letters of `code` the query matched (bold); 0 for an emoticon's row. */
  readonly matched: number;
  /** Where in `code` the matched letters start. */
  readonly matchedAt: number;
}

const wordStart = (code: string, query: string): number => {
  for (let at = code.indexOf(query); at >= 0; at = code.indexOf(query, at + 1))
    if (at === 0 || /[_\-+]/.test(code[at - 1]!)) return at;
  return -1;
};

/// The rows for `trigger`: an emoticon's faces first, then shortcodes ranked exact, prefix of the
/// shown code, a word of it, an alias, then a CLDR name or keyword word; a recent pick ranks up to
/// about one tier higher, never over an exact code.
export function emojiMatches(
  data: EmojiShortcodes,
  trigger: EmojiTrigger,
  prefs: PickerPrefs = RECENTS_EMPTY,
  now = Date.now(),
  limit = EMOJI_SHOWN,
): EmojiMatch[] {
  const out: EmojiMatch[] = [];
  const seen = new Set<string>();
  const push = (match: EmojiMatch) => {
    if (seen.has(match.emoji) || out.length >= limit) return;
    seen.add(match.emoji);
    out.push(match);
  };
  if (trigger.emoticon)
    for (const code of EMOTICONS[trigger.token] ?? []) {
      const record = data.byCode.get(code);
      if (record)
        push({ key: record.emoji, emoji: record.emoji, code: record.shortcodes[0]!, matched: 0, matchedAt: 0 });
    }
  const query = trigger.query;
  if (!query) return out;
  const boost = searchBoost(prefs, (key) => data.byEmoji.get(key), now);
  const scored: { score: number; length: number; index: number; match: EmojiMatch }[] = [];
  for (const record of data.records) {
    const [primary, ...aliases] = record.shortcodes;
    if (!primary) continue;
    let tier = -1;
    let code = primary;
    let at = 0;
    if (primary === query) tier = 0;
    else if (primary.startsWith(query)) tier = 1;
    else if ((at = wordStart(primary, query)) > 0) tier = 2;
    else {
      const alias = aliases.find((name) => wordStart(name, query) >= 0);
      if (alias) {
        tier = 3;
        code = alias;
        at = wordStart(alias, query);
      } else if (record.searchText.includes(`\n${query}`)) {
        tier = 4;
        at = -1;
      }
    }
    if (tier < 0) continue;
    const bonus = tier === 0 ? 0 : (boost.get(record.index) ?? 0);
    scored.push({
      score: tier * 10 - bonus,
      length: code.length,
      index: record.index,
      match: {
        key: record.emoji,
        emoji: record.emoji,
        code,
        matched: at >= 0 ? query.length : 0,
        matchedAt: Math.max(at, 0),
      },
    });
  }
  scored.sort((a, b) => a.score - b.score || a.length - b.length || a.index - b.index);
  for (const { match } of scored) {
    if (out.length >= limit) break;
    push(match);
  }
  return out;
}

const RECENTS_KEY = "cmux.acpmux.recentEmoji";
const RECENTS_EMPTY: PickerPrefs = { tone: 0, recents: [] };

/// The person's recent emoji picks (this Mac's local UI memory, never sent to the host).
export function loadRecentEmoji(): PickerPrefs {
  try {
    return decodePrefs(JSON.parse(globalThis.localStorage?.getItem(RECENTS_KEY) ?? "null"));
  } catch {
    return RECENTS_EMPTY;
  }
}

export function rememberEmoji(emoji: string, now = Date.now()): PickerPrefs {
  const next = recordUse(loadRecentEmoji(), emoji, now);
  try {
    globalThis.localStorage?.setItem(RECENTS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the menu working without recents.
  }
  return next;
}
