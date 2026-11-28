// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover). Typing `:` and two letters at a word start lists
// the emoji whose GitHub shortcode matches; a text emoticon (`:)`, `:DD`, `<3`) lists the face it
// stands for. Picking one writes the glyph over what was typed (Composer.tsx, EmojiMenu.tsx).
//
// The table is the icon picker's (icon-picker/generated/emoji-data.json: Unicode emoji-test.txt and
// CLDR annotations, Unicode License v3; emojibase-data GitHub shortcodes, MIT). It loads in its own
// chunk once the person first types (`loadEmojiShortcodes`, Composer.tsx), never with the page.
import {
  decodeEmojiTable,
  withTone,
  type EmojiRecord,
  type RawEmojiTable,
  type SkinTone,
} from "../../icon-picker/emojiData";
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
  /** The token is a text emoticon (`:)`, `<3`), not a `:shortcode`. */
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
      // Names and keywords are folded in idle slices, not on the first keystroke that needs them:
      // all at once is one ~30 ms task, which would land between the person's keys.
      warmIdle(decoded.records);
      return indexEmoji(decoded.records);
    })
    .catch((error: unknown) => {
      table = undefined;
      throw error;
    });
  return table;
}

/// Folds each record's search text (EmojiRecord.searchText) while the page is idle, a few ms at a time.
function warmIdle(records: readonly EmojiRecord[], from = 0): void {
  const idle = globalThis.requestIdleCallback;
  const slice = (deadline?: IdleDeadline) => {
    let at = from;
    const end = deadline ? Infinity : from + 100;
    while (at < records.length && at < end && (!deadline || deadline.timeRemaining() > 2))
      void records[at++]!.searchText;
    if (at < records.length) warmIdle(records, at);
  };
  if (idle) idle(slice);
  else setTimeout(slice, 0);
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

/// A `:shortcode` starts a word: at the line's start, after a space, an opening bracket or quote,
/// or right after an emoji (`🎉:tada:` is two). Never after a letter, digit or `/`, so a time
/// (`10:30`), a URL (`https://x:8080`) or `key:value` opens nothing.
const OPENER = /^(?:[\s([{"'“‘]|\p{Extended_Pictographic}|\uFE0F|\p{Emoji_Modifier})$/u;
/// Whether a word can start right after `before`.
function startsWord(before: string): boolean {
  if (!before) return true;
  // The last code point: a surrogate pair's two units, else the last unit.
  const last = before.codePointAt(before.length - 2)! > 0xffff ? before.slice(-2) : before.slice(-1);
  return OPENER.test(last);
}
const OPENER_RUN = /^[([{"'“‘]+/;
const CODE = /^:([a-z0-9_+-]+)$/i;

/// The emoji token `before` ends, `before` being the caret's line up to the caret as it shows (an
/// attachment or a code span's characters reach here as U+FFFC, so no token spans one); undefined
/// when it ends none. `start` is where the token starts in `before`.
export function emojiTokenIn(before: string): (Omit<EmojiTrigger, "start"> & { at: number }) | undefined {
  const word = /(?:^|\s)(\S+)$/u.exec(before);
  if (!word) return undefined;
  let token = word[1]!;
  let at = before.length - token.length;
  if (Object.hasOwn(EMOTICONS, token)) {
    const code = CODE.exec(token)?.[1];
    return {
      at,
      token,
      query: code && code.length >= EMOJI_MIN_QUERY ? code.toLowerCase() : undefined,
      emoticon: true,
    };
  }
  // `(:smile`, `"🎉:tada`: the shortcode after the opener or emoji.
  const colon = token.lastIndexOf(":");
  if (colon > 0) {
    if (!startsWord(token.slice(0, colon))) return undefined;
    at += colon;
    token = token.slice(colon);
  } else {
    const opened = OPENER_RUN.exec(token)?.[0].length ?? 0;
    at += opened;
    token = token.slice(opened);
  }
  const code = CODE.exec(token)?.[1];
  if (!code || code.length < EMOJI_MIN_QUERY) return undefined;
  return { at, token, query: code.toLowerCase(), emoticon: false };
}

/// Slack's tone suffix (`:wave::skin-tone-4:`): 1 is the default yellow, 2 to 6 light to dark.
const TONE_SUFFIX = /^skin-tone-([1-6])$/;
const toneOf = (digit: string): SkinTone => (Number(digit) - 1) as SkinTone;

/// The emoji a whole `:code:` names, in `tone` when it takes one; undefined for no such code.
export function shortcodeEmoji(data: EmojiShortcodes, code: string, tone: SkinTone): string | undefined {
  const record = data.byCode.get(code.toLowerCase());
  return record ? withTone(record, tone) : undefined;
}

/// The `:` that closes a known `:code` (or `:code::skin-tone-N`): what it turns into and how many
/// characters of `before` (the caret's line up to the caret, the `:` not in it yet) it replaces.
/// Undefined when `before` ends no known code at a word start (the `:` is only a colon then).
export function closingShortcode(
  data: EmojiShortcodes,
  before: string,
  tone: SkinTone,
): { back: number; emoji: string; key: string; tone?: SkinTone } | undefined {
  // `:skin-tone-N:` right after an emoji that takes a tone (`:wave:` already turned into 👋 as its
  // own `:` was typed, as Slack does): that emoji in tone N.
  const retone = /(\p{Extended_Pictographic})\uFE0F?\p{Emoji_Modifier}?:skin-tone-([1-6])$/iu.exec(before);
  if (retone) {
    const index = data.byEmoji.get(retone[1]!) ?? data.byEmoji.get(`${retone[1]!}\uFE0F`);
    const record = index === undefined ? undefined : data.records[index];
    if (record?.tones) {
      const asked = toneOf(retone[2]!);
      return { back: retone[0].length, emoji: withTone(record, asked), key: record.emoji, tone: asked };
    }
  }
  const toned = /:([a-z0-9_+-]+)::(skin-tone-[1-6])$/i.exec(before);
  const plain = toned ? undefined : /:([a-z0-9_+-]+)$/i.exec(before);
  const found = toned ?? plain;
  if (!found) return undefined;
  const at = found.index;
  if (!startsWord(before.slice(0, at))) return undefined;
  const asked = toned ? toneOf(TONE_SUFFIX.exec(toned[2]!.toLowerCase())![1]!) : undefined;
  const record = data.byCode.get(found[1]!.toLowerCase());
  if (!record) return undefined;
  return { back: before.length - at, emoji: withTone(record, asked ?? tone), key: record.emoji, tone: asked };
}

/// `text` (a paste) with each known `:code:` at a word start written as its emoji. Code spans,
/// fenced blocks and URLs keep theirs; an unknown `:code:` stays as typed.
export function replaceShortcodes(data: EmojiShortcodes, text: string, tone: SkinTone): string {
  if (!text.includes(":")) return text;
  // The paste's code, fenced or in backticks, masked so nothing in it matches.
  const masked = text
    .replace(/^(\s{0,3})(```|~~~)[\s\S]*?(?:^\s{0,3}\2|(?![\s\S]))/gm, (block) => "\0".repeat(block.length))
    .replace(/(`+)[^`]*?\1/g, (span) => "\0".repeat(span.length));
  let out = "";
  let last = 0;
  const pattern = /:([a-z0-9_+-]+):(?::(skin-tone-[1-6]):)?/gi;
  for (let found = pattern.exec(masked); found; found = pattern.exec(masked)) {
    const at = found.index;
    if (at !== last && !startsWord(masked.slice(Math.max(0, at - 2), at))) {
      pattern.lastIndex = at + 1;
      continue;
    }
    const emoji = shortcodeEmoji(data, found[1]!, found[2] ? toneOf(found[2].slice(-1)) : tone);
    if (!emoji) {
      pattern.lastIndex = at + 1;
      continue;
    }
    out += text.slice(last, at) + emoji;
    last = at + found[0].length;
  }
  return last === 0 ? text : out + text.slice(last);
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

/// Whether `query`'s letters appear in `code` in order, from its first letter (`thup` in
/// `thumbsup`): the last tier, for a code half remembered.
function subsequence(code: string, query: string): boolean {
  if (code[0] !== query[0]) return false;
  let at = 0;
  for (const letter of query) {
    at = code.indexOf(letter, at) + 1;
    if (at === 0) return false;
  }
  return true;
}

/// The rows for `trigger`: an emoticon's faces first, then shortcodes ranked exact, prefix of the
/// shown code, a word of it, an alias, a CLDR name or keyword word, then the code's letters in
/// order (`:thup`); a recent or frequent pick ranks up to about one tier higher, never over an
/// exact code. A glyph that takes a skin tone is listed in the person's (`prefs.tone`).
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
        push({
          key: record.emoji,
          emoji: withTone(record, prefs.tone),
          code: record.shortcodes[0]!,
          matched: 0,
          matchedAt: 0,
        });
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
      } else if (query.length >= 3) {
        const loose = record.shortcodes.find((name) => subsequence(name, query));
        if (loose) {
          tier = 5;
          code = loose;
          at = -1;
        }
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
        emoji: withTone(record, prefs.tone),
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

/// Counts a pick of `emoji` (its base, untoned form) toward recent and frequent; `tone`, when
/// given (`:wave::skin-tone-4:`), is the tone toned emoji are written in from then on.
export function rememberEmoji(emoji: string, now = Date.now(), tone?: SkinTone): PickerPrefs {
  const used = recordUse(loadRecentEmoji(), emoji, now);
  const next = tone === undefined ? used : { ...used, tone };
  try {
    globalThis.localStorage?.setItem(RECENTS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the menu working without recents.
  }
  return next;
}
