/**
 * The shared command-palette ranker.
 *
 * Keep this module free of browser APIs so the web palette and the native
 * JavaScriptCore bridge use the same scoring and tie-breaking rules.
 */

export interface PaletteRankEntry {
  title: string;
  keywords?: string[];
  subtitle?: string | null;
  accessory?: string | null;
  rankBias?: number;
  frecencyKey?: string | null;
  isEnabled?: boolean;
  isVisibleWhenQueryEmpty?: boolean;
  queryPrefix?: string | null;
  hidesWhenTyping?: boolean;
  sectionIndex?: number;
  /** The row enters a palette scope (`PaletteItem.enters`). */
  entersScope?: boolean;
  /** The section the row joins while the user types (the root merges all rows into one list). */
  typingSectionIndex?: number | null;
  /** The registry action id; found only by a query that is the id or starts it (4+ letters). */
  actionID?: string | null;
  /** A row of a secondary kind (a setting): one tier lower than a command with the same match. */
  demoted?: boolean;
  /** The row has a keyboard shortcut: a core command, first among equal matches. */
  hasShortcut?: boolean;
}

export interface PaletteFrecencyEntry {
  score: number;
  lastUsed: number;
}

export interface PaletteFrecency {
  entries?: Record<string, PaletteFrecencyEntry>;
  halfLife?: number;
  capacity?: number;
}

export interface PaletteRankedRow {
  index: number;
  score: number;
  highlights: number[];
}

export interface PaletteRankedSection {
  sectionIndex: number | null;
  rows: PaletteRankedRow[];
}

export interface PaletteRankRequest {
  operation: "rank" | "rankEmpty";
  entries: readonly PaletteRankEntry[];
  /** Stable snapshot version supplied by the native searcher for reuse. */
  version?: number;
  query?: string;
  sectionOrders?: number[];
  frecency?: PaletteFrecency;
  now?: number;
  showsRecent?: boolean;
  keepsSectionOrder?: boolean;
  ranksPrefixFirst?: boolean;
  recentLimit?: number;
  rowLimit?: number;
  highlightLimit?: number;
}

/** Below every enabled row of any tier. */
const disabledPenalty = 10_000;
const titleWeight = 100;
const keywordWeight = 80;
const subtitleWeight = 65;
const accessoryWeight = 50;
const maximumBoost = 60;
const defaultHalfLife = 3 * 24 * 60 * 60;

let cachedVersion: number | undefined;
let cachedFields: Field[][] = [];

type CharClass = "lower" | "upper" | "digit" | "delimiter" | "ideograph" | "other";

interface FoldedText {
  original: string[];
  folded: string[];
  bonus: number[];
  initials: string[];
  mask: bigint;
}

interface Field {
  text: FoldedText;
  weight: number;
}

interface Query {
  raw: string;
  tokens: string[][];
  tokenMasks: bigint[];
  mask: bigint;
  joined: string[];
  phrase: string[];
  flat: string[];
  ranges: Array<{ start: number; end: number }>;
}

interface TokenMatch {
  score: number;
  start: number;
  end: number;
}

function foldScalar(scalar: string): string {
  const ascii = scalar.codePointAt(0) ?? 0;
  if (ascii >= 0x41 && ascii <= 0x5a) return String.fromCodePoint(ascii + 0x20);
  const folded = scalar
    .normalize("NFKD")
    .toLocaleLowerCase()
    .replace(/[\u0300-\u036f]/gu, "");
  return Array.from(folded)[0] ?? scalar;
}

function charClass(scalar: string): CharClass {
  const value = scalar.codePointAt(0) ?? 0;
  if (value >= 0x61 && value <= 0x7a) return "lower";
  if (value >= 0x41 && value <= 0x5a) return "upper";
  if (value >= 0x30 && value <= 0x39) return "digit";
  if (
    scalar === " " ||
    scalar === "\t" ||
    "-_./:,()[]<>…、。".includes(scalar) ||
    scalar === "（" ||
    scalar === "）" ||
    /\s/u.test(scalar)
  )
    return "delimiter";
  if (
    (value >= 0x3040 && value <= 0x30ff) ||
    (value >= 0x3400 && value <= 0x9fff) ||
    (value >= 0xac00 && value <= 0xd7af)
  )
    return "ideograph";
  if (/\p{Lu}/u.test(scalar)) return "upper";
  if (/\p{Ll}/u.test(scalar)) return "lower";
  return "other";
}

function maskBit(folded: string): bigint {
  const value = folded.codePointAt(0) ?? 0;
  if (value >= 0x61 && value <= 0x7a) return 1n << BigInt(value - 0x61);
  if (value >= 0x30 && value <= 0x39) return 1n << BigInt(26 + value - 0x30);
  if (value === 0x20) return 0n;
  return 1n << BigInt(36 + (value % 28));
}

function maskOf(scalars: readonly string[]): bigint {
  return scalars.reduce((mask, scalar) => mask | maskBit(scalar), 0n);
}

function boundaryBonus(previous: CharClass, current: CharClass, first: boolean): number {
  if (current === "delimiter") return 0;
  if (current === "ideograph") return first ? 10 : 3;
  if (first) return 10;
  if (previous === "delimiter") return 9;
  if (previous === "lower" && current === "upper") return 7;
  if (previous === "ideograph") return 9;
  if ((previous === "lower" || previous === "upper") && current === "digit") return 4;
  if (previous === "digit" && (current === "lower" || current === "upper")) return 4;
  return 0;
}

function prepareText(original: string): FoldedText {
  const originalScalars = Array.from(original);
  const folded: string[] = [];
  const bonus: number[] = [];
  const initials: string[] = [];
  let mask = 0n;
  let previous: CharClass = "delimiter";
  originalScalars.forEach((scalar, index) => {
    const foldedScalar = foldScalar(scalar);
    const current = charClass(scalar);
    const b = boundaryBonus(previous, current, index === 0);
    folded.push(foldedScalar);
    bonus.push(b);
    mask |= maskBit(foldedScalar);
    if (b >= 7 && current !== "delimiter" && current !== "ideograph") initials.push(foldedScalar);
    previous = current;
  });
  return { original: originalScalars, folded, bonus, initials, mask };
}

function makeQuery(raw: string): Query {
  const words = raw.trim().split(/\s+/u).filter(Boolean);
  const tokens = words.map((word) => Array.from(word).map(foldScalar));
  const tokenMasks = tokens.map(maskOf);
  const mask = tokenMasks.reduce((value, tokenMask) => value | tokenMask, 0n);
  const joined = tokens.flat();
  const phrase = Array.from(words.join(" ")).map(foldScalar);
  const ranges: Array<{ start: number; end: number }> = [];
  let offset = 0;
  for (const token of tokens) {
    ranges.push({ start: offset, end: offset + token.length });
    offset += token.length;
  }
  return { raw, tokens, tokenMasks, mask, joined, phrase, flat: joined, ranges };
}

function queryIsEmpty(query: Query): boolean {
  return query.tokens.length === 0;
}

function hasPrefix(value: readonly string[], prefix: readonly string[]): boolean {
  if (prefix.length > value.length) return false;
  return prefix.every((scalar, index) => value[index] === scalar);
}

function substringStart(
  needle: readonly string[],
  folded: readonly string[],
  bonuses: readonly number[],
  requireBoundary: boolean,
): number | null {
  if (!needle.length || needle.length > folded.length) return null;
  const first = needle[0];
  for (let start = 0; start <= folded.length - needle.length; start++) {
    if (folded[start] !== first || (requireBoundary && bonuses[start] < 7)) continue;
    let i = 1;
    while (i < needle.length && folded[start + i] === needle[i]) i++;
    if (i === needle.length) return start;
  }
  return null;
}

function windowScore(
  token: readonly string[],
  folded: readonly string[],
  bonuses: readonly number[],
  start: number,
  end: number,
): number {
  let score = 0;
  let tokenIndex = 0;
  let previousMatch = -2;
  let runBonus = 0;
  for (let index = start; index <= end && tokenIndex < token.length; index++) {
    if (folded[index] === token[tokenIndex]) {
      let bonus = bonuses[index];
      if (index === previousMatch + 1) {
        bonus = Math.max(bonus, runBonus);
        score += 5;
      } else {
        runBonus = bonus;
      }
      if (tokenIndex === 0) bonus *= 2;
      score += 16 + bonus;
      previousMatch = index;
      tokenIndex++;
    } else {
      score -= index === previousMatch + 1 ? 3 : 1;
    }
  }
  return score - Math.min(start, 12);
}

function forwardWindowEnd(token: readonly string[], folded: readonly string[], start: number): number | null {
  let tokenIndex = 0;
  for (let index = start; index < folded.length; index++) {
    if (folded[index] === token[tokenIndex]) {
      tokenIndex++;
      if (tokenIndex === token.length) return index;
    }
  }
  return null;
}

function tokenScore(token: readonly string[], text: FoldedText): TokenMatch | null {
  if (!token.length) return { score: 0, start: 0, end: 0 };
  if (token.length > text.folded.length) return null;
  const contiguousStart = substringStart(token, text.folded, text.bonus, true);
  if (contiguousStart !== null) {
    return {
      score: windowScore(token, text.folded, text.bonus, contiguousStart, contiguousStart + token.length - 1),
      start: contiguousStart,
      end: contiguousStart + token.length - 1,
    };
  }

  let tokenIndex = 0;
  let end = -1;
  for (let index = 0; index < text.folded.length; index++) {
    if (text.folded[index] === token[tokenIndex]) {
      tokenIndex++;
      if (tokenIndex === token.length) {
        end = index;
        break;
      }
    }
  }
  if (end < 0) return null;

  tokenIndex = token.length - 1;
  let start = end;
  for (let index = end; index >= 0; index--) {
    if (text.folded[index] === token[tokenIndex]) {
      if (tokenIndex === 0) {
        start = index;
        break;
      }
      tokenIndex--;
    }
  }
  let best = windowScore(token, text.folded, text.bonus, start, end);
  if (text.bonus[start] < 9) {
    const first = token[0];
    for (let index = 0; index < text.folded.length; index++) {
      if (text.folded[index] !== first || text.bonus[index] < 7 || index === start) continue;
      const alternateEnd = forwardWindowEnd(token, text.folded, index);
      if (alternateEnd === null) break;
      const alternate = windowScore(token, text.folded, text.bonus, index, alternateEnd);
      if (alternate > best) {
        best = alternate;
        start = index;
        end = alternateEnd;
      }
      break;
    }
  }
  return { score: best, start, end };
}

function phraseBonus(query: Query, text: FoldedText): number {
  if (!query.phrase.length || query.phrase.length > text.folded.length) return 0;
  if (hasPrefix(text.folded, query.phrase)) return query.phrase.length === text.folded.length ? 220 : 90;
  if (query.joined.length >= 2 && hasPrefix(text.initials, query.joined)) return 70;
  if (query.phrase.length >= 2 && substringStart(query.phrase, text.folded, text.bonus, true) !== null) return 30;
  return 0;
}

function fieldsFor(entry: PaletteRankEntry): Field[] {
  const fields: Field[] = [{ text: prepareText(entry.title), weight: titleWeight }];
  if (entry.keywords?.length) fields.push({ text: prepareText(entry.keywords.join(" ")), weight: keywordWeight });
  if (entry.subtitle) fields.push({ text: prepareText(entry.subtitle), weight: subtitleWeight });
  if (entry.accessory) fields.push({ text: prepareText(entry.accessory), weight: accessoryWeight });
  return fields;
}

function fieldsForEntries(entries: readonly PaletteRankEntry[], version: number | undefined): Field[][] {
  if (version !== undefined && cachedVersion === version && cachedFields.length === entries.length) return cachedFields;
  const fields = entries.map(fieldsFor);
  if (version !== undefined) {
    cachedVersion = version;
    cachedFields = fields;
  }
  return fields;
}

/**
 * Match classes, best first (plans/cmux-next/palette-ranking.md section 5). A row's class
 * decides its order before any quality, usage or bias: usage lifts a row inside its class,
 * never over a clearly better match.
 */
export const matchTier = {
  /** The whole title is the query. */
  wholeTitle: 6,
  /** A scope row whose keyword is the whole query ("settings" for the settings scope). */
  scopeKeyword: 5.5,
  /** The title starts with the query, in whole words ("split" for Split Right). */
  titlePrefix: 5,
  /** Every token is a whole title word ("chat" for New Agent Chat). */
  wholeWords: 4.5,
  /** The title starts with the query, the last word cut ("brows" for Browser Profiles). */
  titlePartialPrefix: 4,
  /** Every token starts a title word ("brows" for New Browser Tab). */
  titleWords: 3.5,
  /** The query is the start of the title's word initials ("sr", "nac"). */
  acronym: 3,
  /** Every token is a title substring or starts a keyword. */
  substring: 2,
  /** A token is one edit away from a title word ("spilt", "sttings"). */
  typo: 1.5,
  /** Every token matches in order from a word start, or starts a subtitle word. */
  fuzzy: 1,
} as const;

const tierScale = 1_000;
const maximumQuality = 880;
/** Lifts a row with a shortcut over its unbound siblings ("Split Right" over "Split Up"); far less than a tier. */
const shortcutBonus = 40;

/** How well one token matches one field: 3 starts a word, 2 contiguous, 1 in order from a word start, 0 none. */
function tokenLevel(token: readonly string[], text: FoldedText): number {
  if (!token.length) return 3;
  if (substringStart(token, text.folded, text.bonus, true) !== null) return 3;
  if (substringStart(token, text.folded, text.bonus, false) !== null) return 2;
  for (let index = 0; index < text.folded.length; index++) {
    if (text.folded[index] !== token[0] || text.bonus[index] < 7) continue;
    if (forwardWindowEnd(token, text.folded, index) !== null) return 1;
  }
  return 0;
}

/** The entry tier one token reaches through its best field (title levels count fully, others less). */
function tokenTier(token: readonly string[], fields: readonly Field[]): number {
  let best = -1;
  for (const field of fields) {
    const level = tokenLevel(token, field.text);
    if (!level) continue;
    let tier: number;
    if (field.weight === titleWeight) tier = level >= 2 ? matchTier.substring : matchTier.fuzzy;
    else if (field.weight === keywordWeight) tier = level === 3 ? matchTier.substring : -1;
    else tier = level === 3 ? matchTier.fuzzy : -1;
    best = Math.max(best, tier);
  }
  return best;
}

/** Title words (folded scalars), split at delimiters. */
function titleWords(text: FoldedText): string[][] {
  const words: string[][] = [];
  let current: string[] = [];
  text.original.forEach((scalar, index) => {
    if (charClass(scalar) === "delimiter") {
      if (current.length) words.push(current);
      current = [];
    } else current.push(text.folded[index]);
  });
  if (current.length) words.push(current);
  return words;
}

/** Optimal string alignment distance, stopping early above 1. */
function withinOneEdit(a: readonly string[], b: readonly string[]): boolean {
  if (Math.abs(a.length - b.length) > 1) return false;
  const rows = a.length + 1;
  const cols = b.length + 1;
  const d: number[][] = Array.from({ length: rows }, (_, i) =>
    Array.from({ length: cols }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)),
  );
  for (let i = 1; i < rows; i++) {
    let rowMin = Number.POSITIVE_INFINITY;
    for (let j = 1; j < cols; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let value = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1])
        value = Math.min(value, d[i - 2][j - 2] + 1);
      d[i][j] = value;
      rowMin = Math.min(rowMin, value);
    }
    if (rowMin > 1) return false;
  }
  return d[a.length][b.length] <= 1;
}

/** One adjacent swap and nothing else ("tba" for "tab"). */
function isTransposition(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  const diff: number[] = [];
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) diff.push(i);
  return diff.length === 2 && diff[1] === diff[0] + 1 && a[diff[0]] === b[diff[1]] && a[diff[1]] === b[diff[0]];
}

/**
 * Whether every token matches the title strictly or within one edit of a title word (or its
 * prefix). Tokens of 4 or more letters allow any one edit; 3-letter tokens only a swap.
 */
function typoCorrection(query: Query, title: FoldedText): Query | null {
  const words = titleWords(title);
  let typos = 0;
  const corrected: string[] = [];
  for (const token of query.tokens) {
    if (tokenLevel(token, title) >= 2) {
      corrected.push(token.join(""));
      continue;
    }
    if (token.length < 3) return null;
    const close = words.find((word) => {
      if (token.length === 3) return isTransposition(token, word.slice(0, 3));
      return (
        withinOneEdit(token, word) ||
        withinOneEdit(token, word.slice(0, token.length)) ||
        withinOneEdit(token, word.slice(0, token.length + 1)) ||
        withinOneEdit(token, word.slice(0, token.length - 1))
      );
    });
    if (!close) return null;
    corrected.push(close.join(""));
    typos++;
  }
  return typos > 0 ? makeQuery(corrected.join(" ")) : null;
}

/** Whether `token` occurs in the title as a whole word. */
function isWholeWord(token: readonly string[], text: FoldedText): boolean {
  return titleWords(text).some((word) => word.length === token.length && hasPrefix(word, token));
}

/** Whether the title starts with the query phrase and the phrase ends at a word end. */
function startsWithWholeWords(query: Query, text: FoldedText): boolean {
  if (!hasPrefix(text.folded, query.phrase)) return false;
  const next = text.original[query.phrase.length];
  return next === undefined || charClass(next) === "delimiter" || text.bonus[query.phrase.length] >= 7;
}

/** A one-word query that is the action id (`newSurface`) or starts it. */
function actionIDTier(entry: PaletteRankEntry, query: Query): number | null {
  if (!entry.actionID || query.tokens.length !== 1 || query.joined.length < 4) return null;
  const id = Array.from(entry.actionID).map(foldScalar);
  if (!hasPrefix(id, query.joined)) return null;
  return id.length === query.joined.length ? matchTier.titlePrefix : matchTier.substring;
}

/** The row's tier and the query its quality is measured with (a typo row: the corrected one). */
function entryTier(
  entry: PaletteRankEntry,
  query: Query,
  fields: readonly Field[],
): { tier: number; query: Query } | null {
  const byText = textTier(entry, query, fields);
  const byID = actionIDTier(entry, query);
  if (!byText) return byID === null ? null : { tier: byID, query };
  if (byID !== null && byID > byText.tier) return { tier: byID, query };
  if (entry.demoted) return { tier: byText.tier - 1, query: byText.query };
  return byText;
}

function textTier(
  entry: PaletteRankEntry,
  query: Query,
  fields: readonly Field[],
): { tier: number; query: Query } | null {
  const title = fields[0].text;
  const tiered = (tier: number) => ({ tier, query });
  if (titleIsQuery(entry.title, query.raw)) return tiered(matchTier.wholeTitle);
  if (entry.entersScope && entry.keywords?.some((keyword) => titleIsQuery(keyword, query.raw)))
    return tiered(matchTier.scopeKeyword);
  if (startsWithWholeWords(query, title)) return tiered(matchTier.titlePrefix);
  if (query.tokens.every((token) => isWholeWord(token, title))) return tiered(matchTier.wholeWords);
  if (hasPrefix(title.folded, query.phrase)) return tiered(matchTier.titlePartialPrefix);
  if (query.tokens.every((token) => tokenLevel(token, title) === 3)) return tiered(matchTier.titleWords);
  if (query.tokens.length === 1 && query.joined.length >= 2 && hasPrefix(title.initials, query.joined))
    return tiered(matchTier.acronym);
  let tier: number = matchTier.substring;
  for (const token of query.tokens) {
    const reached = tokenTier(token, fields);
    if (reached < 0) {
      tier = -1;
      break;
    }
    tier = Math.min(tier, reached);
  }
  // One edit away from a real title word is a better answer than scattered letters.
  if (tier <= matchTier.fuzzy) {
    const corrected = typoCorrection(query, title);
    if (corrected) return { tier: matchTier.typo, query: corrected };
  }
  return tier < 0 ? null : tiered(tier);
}

function highlightsFor(query: Query, title: FoldedText): number[] {
  const phraseStart = substringStart(query.phrase, title.folded, title.bonus, false);
  if (phraseStart !== null) {
    return Array.from({ length: query.phrase.length }, (_, offset) => phraseStart + offset).filter(
      (index) => title.folded[index] !== " ",
    );
  }
  const positions = new Set<number>();
  for (const token of query.tokens) {
    const match = tokenScore(token, title);
    if (!match) continue;
    let matched = 0;
    for (let index = match.start; index <= match.end && matched < token.length; index++) {
      if (title.folded[index] === token[matched]) {
        positions.add(index);
        matched++;
      }
    }
  }
  return [...positions].sort((a, b) => a - b);
}

/** The match quality inside a tier: contiguity and word-start bonuses per token, a phrase bonus, shorter titles first. */
function matchQuality(query: Query, fields: readonly Field[]): number {
  let total = 0;
  for (let tokenIndex = 0; tokenIndex < query.tokens.length; tokenIndex++) {
    const token = query.tokens[tokenIndex];
    const tokenMask = query.tokenMasks[tokenIndex];
    let best = 0;
    for (const field of fields) {
      if ((field.text.mask & tokenMask) !== tokenMask) continue;
      const match = tokenScore(token, field.text);
      if (match) best = Math.max(best, Math.trunc((match.score * field.weight) / 100));
    }
    total += best;
  }
  let bonus = 0;
  for (const field of fields) {
    if ((field.text.mask & query.mask) === query.mask)
      bonus = Math.max(bonus, Math.trunc((phraseBonus(query, field.text) * field.weight) / 100));
  }
  const title = fields[0].text;
  // A query that is the title's whole initials ("sr" for Split Right) beats a longer title.
  const initialsBonus =
    query.joined.length >= 2 && title.initials.length === query.joined.length && hasPrefix(title.initials, query.joined)
      ? 40
      : 0;
  const quality = total + bonus + initialsBonus - Math.floor(title.folded.length / 6);
  return Math.max(0, Math.min(maximumQuality, quality));
}

function scoreEntry(
  entry: PaletteRankEntry,
  query: Query,
  fields: Field[],
): { score: number; highlights: number[] } | null {
  if (queryIsEmpty(query)) return { score: 0, highlights: [] };
  const match = entryTier(entry, query, fields);
  if (!match) return null;
  // Whole-title rows tie on quality ("Settings" and "Settings…"), so the provider order decides.
  const quality = match.tier >= matchTier.wholeTitle ? maximumQuality : matchQuality(match.query, fields);
  return {
    score: Math.round(match.tier * tierScale) + quality,
    highlights: highlightsFor(match.query, fields[0].text),
  };
}

function frecencyScore(store: PaletteFrecency | undefined, key: string | null | undefined, now: number): number {
  if (!store?.entries || !key) return 0;
  const entry = store.entries[key];
  if (!entry) return 0;
  const halfLife = store.halfLife ?? defaultHalfLife;
  const elapsed = Math.max(0, now - entry.lastUsed);
  return entry.score * 2 ** (-elapsed / halfLife);
}

function frecencyBoost(store: PaletteFrecency | undefined, key: string | null | undefined, now: number): number {
  const score = frecencyScore(store, key, now);
  if (score <= 0.01) return 0;
  return Math.min(maximumBoost, Math.round(18 * Math.log2(1 + score)));
}

function topFrecencyKeys(store: PaletteFrecency | undefined, limit: number, now: number): string[] {
  if (!store?.entries) return [];
  return Object.keys(store.entries)
    .map((key) => ({ key, score: frecencyScore(store, key, now) }))
    .filter((item) => item.score >= 0.05)
    .sort((a, b) => b.score - a.score || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    .slice(0, limit)
    .map((item) => item.key);
}

function sectionOrder(sections: number[], orders: readonly number[]): void {
  sections.sort((a, b) => {
    const left = a < orders.length ? orders[a] : Number.POSITIVE_INFINITY;
    const right = b < orders.length ? orders[b] : Number.POSITIVE_INFINITY;
    return left !== right ? left - right : a - b;
  });
}

export function rankPaletteEmpty(request: Omit<PaletteRankRequest, "operation">): PaletteRankedSection[] {
  const entries = request.entries;
  const orders = request.sectionOrders ?? [];
  const store = request.frecency;
  const now = request.now ?? 0;
  const recentLimit = request.recentLimit ?? 5;
  const recent = new Set<number>();
  const sections: PaletteRankedSection[] = [];
  if (request.showsRecent && recentLimit > 0 && store?.entries && Object.keys(store.entries).length > 0) {
    const positionByKey = new Map<string, number>();
    entries.forEach((entry, index) => {
      if (
        (entry.isEnabled ?? true) &&
        (entry.isVisibleWhenQueryEmpty ?? true) &&
        entry.frecencyKey &&
        !positionByKey.has(entry.frecencyKey)
      )
        positionByKey.set(entry.frecencyKey, index);
    });
    const rows = topFrecencyKeys(store, recentLimit * 3, now)
      .map((key) => positionByKey.get(key))
      .filter((index): index is number => index !== undefined)
      .slice(0, recentLimit)
      .map((index) => ({ index, score: 0, highlights: [] }));
    if (rows.length) {
      rows.forEach((row) => recent.add(row.index));
      sections.push({ sectionIndex: null, rows });
    }
  }
  const order: number[] = [];
  const rowsBySection = new Map<number, PaletteRankedRow[]>();
  entries.forEach((entry, index) => {
    if (!(entry.isVisibleWhenQueryEmpty ?? true) || recent.has(index)) return;
    const section = entry.sectionIndex ?? 0;
    if (!rowsBySection.has(section)) order.push(section);
    rowsBySection.set(section, [...(rowsBySection.get(section) ?? []), { index, score: 0, highlights: [] }]);
  });
  sectionOrder(order, orders);
  sections.push(...order.map((sectionIndex) => ({ sectionIndex, rows: rowsBySection.get(sectionIndex) ?? [] })));
  return sections;
}

export function rankPalette(request: Omit<PaletteRankRequest, "operation">): PaletteRankedSection[] {
  const query = makeQuery(request.query ?? "");
  if (queryIsEmpty(query)) return rankPaletteEmpty(request);
  const entries = request.entries;
  const store = request.frecency;
  const now = request.now ?? 0;
  const gated = entries.some((entry) => entry.queryPrefix != null || entry.hidesWhenTyping === true);
  const prepared = fieldsForEntries(entries, request.version);
  const scored: Array<{ index: number; score: number; highlights: number[] }> = [];
  entries.forEach((entry, index) => {
    if (gated && entry.hidesWhenTyping) return;
    if (gated && entry.queryPrefix != null && !query.raw.startsWith(entry.queryPrefix)) return;
    const match = scoreEntry(entry, query, prepared[index]);
    if (!match) return;
    let score = match.score + (entry.rankBias ?? 0) + frecencyBoost(store, entry.frecencyKey, now);
    if (entry.hasShortcut) score += shortcutBonus;
    if (entry.isEnabled === false) score -= disabledPenalty;
    scored.push({ index, score, highlights: match.highlights });
  });
  if (request.ranksPrefixFirst) {
    const prefix = query.raw.trim().toLocaleLowerCase();
    const starts = new Set(
      scored
        .filter((item) => entries[item.index].title.toLocaleLowerCase().startsWith(prefix))
        .map((item) => item.index),
    );
    scored.sort((left, right) => {
      const leftStarts = starts.has(left.index);
      const rightStarts = starts.has(right.index);
      if (leftStarts !== rightStarts) return leftStarts ? -1 : 1;
      if (leftStarts) return left.index - right.index;
      return right.score - left.score || left.index - right.index;
    });
  } else {
    // Equal scores keep the provider order (the catalog lists the common command of a family first).
    scored.sort((left, right) => right.score - left.score || left.index - right.index);
  }
  const rowLimit = request.rowLimit ?? 400;
  const highlightLimit = request.highlightLimit ?? 60;
  const order: number[] = [];
  const rowsBySection = new Map<number, PaletteRankedRow[]>();
  scored.slice(0, rowLimit).forEach((item, rank) => {
    const entry = entries[item.index];
    const section = entry.typingSectionIndex ?? entry.sectionIndex ?? 0;
    let rows = rowsBySection.get(section);
    if (!rows) {
      rows = [];
      rowsBySection.set(section, rows);
      order.push(section);
    }
    rows.push({ index: item.index, score: item.score, highlights: rank < highlightLimit ? item.highlights : [] });
  });
  if (request.keepsSectionOrder) sectionOrder(order, request.sectionOrders ?? []);
  return order.map((sectionIndex) => ({ sectionIndex, rows: rowsBySection.get(sectionIndex) ?? [] }));
}

/** Whether `title` (or a keyword) is the whole query, ignoring case, surrounding space and a trailing ellipsis. */
function titleIsQuery(title: string, raw: string): boolean {
  const normalize = (text: string) =>
    text
      .trim()
      .replace(/(\u2026|\.\.\.)$/u, "")
      .trim()
      .toLocaleLowerCase();
  const query = normalize(raw);
  return query !== "" && normalize(title) === query;
}

export function rankPaletteRequest(request: PaletteRankRequest): PaletteRankedSection[] {
  return request.operation === "rankEmpty" ? rankPaletteEmpty(request) : rankPalette(request);
}
