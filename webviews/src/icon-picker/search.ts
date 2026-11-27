// Ranked search over picker items (emoji and symbols share it). Every query token must match;
// a token scores by where it matches: the whole name, a name prefix, a word prefix in the name,
// a keyword prefix, or (two characters or more, needed for Japanese, which has no spaces)
// anywhere in the text. Ties keep recents first, then the table order. A linear scan of ~1900
// emoji costs well under a millisecond, so no index structure is needed.
import { fold } from "./emojiData";

export interface Searchable {
  readonly index: number;
  /** "\n"-prefixed folded names. */
  readonly nameText: string;
  /** "\n"-prefixed folded names, words and keywords. */
  readonly searchText: string;
}

export function queryTokens(query: string): string[] {
  return fold(query)
    .split(/[\s:,]+/u)
    .filter(Boolean);
}

const isWordChar = (ch: string | undefined) => !!ch && /[\p{L}\p{N}]/u.test(ch) && ch !== "\n";

/**
 * Scores of a match, best first: the whole entry, a whole word that starts the entry, a whole
 * word elsewhere, a word prefix that starts the entry, a word prefix elsewhere.
 */
type Tiers = readonly [number, number, number, number, number];
const NAME_TIERS: Tiers = [100, 90, 80, 75, 70];
const KEYWORD_TIERS: Tiers = [50, 48, 46, 44, 40];

/** Best tier of `token` inside `text` ("\n"-separated folded entries); 0 when absent. */
function bestTier(text: string, token: string, tiers: Tiers): number {
  let best = 0;
  for (let at = text.indexOf(token); at >= 0; at = text.indexOf(token, at + 1)) {
    const before = text[at - 1];
    const after = text[at + token.length];
    const entryStart = before === "\n";
    if (!entryStart && isWordChar(before)) continue;
    const entryEnd = after === undefined || after === "\n";
    const wordEnd = !isWordChar(after);
    let tier: number;
    if (entryStart && entryEnd) tier = tiers[0];
    else if (wordEnd) tier = entryStart ? tiers[1] : tiers[2];
    else tier = entryStart ? tiers[3] : tiers[4];
    best = Math.max(best, tier);
  }
  return best;
}

function tokenScore(item: Searchable, token: string): number {
  const name = bestTier(item.nameText, token, NAME_TIERS);
  if (name) return name;
  const keyword = bestTier(item.searchText, token, KEYWORD_TIERS);
  if (keyword) return keyword;
  // Inside a word: Japanese has no spaces, so this is how most Japanese queries match.
  const substring = token.length >= 2 || !/[a-z0-9]/.test(token);
  return substring && item.searchText.includes(token) ? 10 : 0;
}

/**
 * The items matching every token, best first. `boost` (recents) breaks ties and adds a small
 * bonus so a frequent emoji outranks an equally good match; `limit` caps the result.
 */
export function search<T extends Searchable>(
  items: readonly T[],
  query: string,
  boost: ReadonlyMap<number, number> = new Map(),
  limit = Infinity,
): T[] {
  const tokens = queryTokens(query);
  if (tokens.length === 0) return items.slice(0, limit);
  const scored: { item: T; score: number }[] = [];
  outer: for (const item of items) {
    let score = 0;
    for (const token of tokens) {
      const s = tokenScore(item, token);
      if (s === 0) continue outer;
      score += s;
    }
    // Shorter names first among equal scores ("red heart" before "heart with arrow").
    scored.push({ item, score: (score + (boost.get(item.index) ?? 0)) * 1000 - Math.min(999, item.nameText.length) });
  }
  scored.sort((a, b) => b.score - a.score || a.item.index - b.item.index);
  const out: T[] = [];
  for (const { item } of scored) {
    if (out.length >= limit) break;
    out.push(item);
  }
  return out;
}
