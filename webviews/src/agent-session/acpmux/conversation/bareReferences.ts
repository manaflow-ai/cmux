// Which repository a bare `#N` in the transcript means (Leo 2026-10-22: "in a nother chat it kept
// only linking to leo-workspace and not the cmux repo"). A coordinator chat whose folder is
// leo-workspace writes cmux pull request numbers, and reading every bare `#N` as the folder's
// linked each one to the wrong repository. Strongest evidence first:
//
// 1. `owner/repo#N` and a GitHub address name their own repository (githubReferences.ts).
// 2. A bare `#N` takes
//    a. the repository its own turn names for N: `manaflow-ai/cmux#24175` or its address, in the
//       prompt or agent message that opened the turn, a reply, or a command and its output;
//    b. else the repository the chat named N with last before the turn (a later turn never
//       changes an earlier turn's link);
//    c. else the candidate that has pull request N, as the App's pull request cache says
//       (chips/referenceExistence.ts): the folder's repository, then the ones the chat linked;
//    d. else the folder's repository (or the transcript's, transcriptRepositories.ts).
// 3. A number that is a pull request in two or more candidates names its repository on the chip
//    (`leo-workspace#843`).
// 4. Rules c and d only take a candidate whose numbers the chat named are no longer than N: a cmux
//    chat that named #27262 means no pull request by "#1 / #2" (Leo 2026-10-29: "these auto
//    render to the pr instead of just #1 #2..."). With no candidate left, N is text.
import { createContext } from "react";
import { githubReferences, isGithubOwner } from "../../../githubReferences";
import type { AcpmuxRow } from "../model";
import { LayeredMap } from "./layeredMap";
import { rowsDelta, type RowsDelta } from "./rowsDelta";

/// `at` is a row's place (ReferenceScopeCache `base`): only its order with other places is read.
type Mention = { at: number; repo: string };

/** What the whole transcript says, shared by every row. */
export type ReferenceEvidence = {
  /** Rule b: where the chat named each number, in transcript order. */
  mentions: ReadonlyMap<number, readonly Mention[]>;
  /** Rule c's candidates after the folder's: the repositories the chat linked, latest first. */
  linked: readonly string[];
  /** Rule 4: the smallest number the chat named in each repository, by its lowercase name. */
  smallest: ReadonlyMap<string, number>;
};

/** A turn's evidence: the transcript's, its own (rule a), and where it starts (a place, ordered
 *  with the mentions' places: rule b reads the mentions before it). */
export type ReferenceScope = { evidence: ReferenceEvidence; turn: ReadonlyMap<number, string>; at: number };

/** The row a chip draws in (App.tsx VirtualTranscript); null outside a transcript. */
export const ReferenceScopeContext = createContext<ReferenceScope | null>(null);

/** The most candidates rule c asks about for one number, the folder's included. */
export const MAX_CANDIDATES = 3;

type Named = { number?: number; repo: string };

/** The fields of a client row the reading reads. */
type ReadRow = Pick<AcpmuxRow, "id" | "kind" | "text" | "items">;

// A repository's address, with the pull request or issue it names; `.git` is not part of a name.
const ADDRESS =
  /(?<![\w.-])(?:https?:\/\/)?(?:www\.)?github\.com\/([A-Za-z0-9][\w.-]*\/[A-Za-z0-9][\w-]*(?:\.(?!git\b)[\w-]+)*)(?:\.git)?(?:\/(?:pull|issues)\/([1-9][0-9]{0,9})(?![0-9]))?/g;
// `-R owner/repo` or `--repo owner/repo` in a command.
const REPO_FLAG = /(?:^|\s)(?:-R|--repo)[= ]([A-Za-z0-9][\w.-]*\/[A-Za-z0-9][\w.-]*)(?=\s|$)/g;

/** Every repository `text` names, in order, with the number it names: addresses, `owner/repo#N`,
 *  `hq#N`, a repository's own address and a command's `-R owner/repo`. */
export function namedReferences(text: string): Named[] {
  if (!/#|github\.com|-R|--repo/.test(text)) return [];
  const out: (Named & { start: number })[] = [];
  for (const match of text.matchAll(ADDRESS))
    if (isGithubOwner(match[1]!.split("/")[0]!))
      out.push({ start: match.index!, repo: match[1]!, ...(match[2] ? { number: Number(match[2]) } : {}) });
  for (const match of text.matchAll(REPO_FLAG)) out.push({ start: match.index!, repo: match[1]! });
  for (const ref of githubReferences(text, undefined, "pull", true)) {
    const address = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)$/.exec(ref.href);
    if (address) out.push({ start: ref.start, repo: address[1]!, number: Number(address[2]) });
  }
  return out.sort((a, b) => a.start - b.start).map(({ repo, number }) => (number ? { repo, number } : { repo }));
}

/** Each row's named repositories, for the row object they were read from. */
const rowCache = new WeakMap<object, readonly Named[]>();

function rowNamed(row: Pick<AcpmuxRow, "kind" | "text" | "items">): readonly Named[] {
  const kept = rowCache.get(row);
  if (kept) return kept;
  let named: Named[] = [];
  if ((row.kind === "user" || row.kind === "assistant") && row.text) named = namedReferences(row.text);
  else if (row.kind === "activity")
    // A command that failed (`gh pr view 12 -R o/r` with no such pull request) is no evidence.
    named = (row.items ?? []).flatMap(({ tool }) =>
      tool && tool.status === "completed" && (tool.exitCode ?? 0) === 0
        ? [...namedReferences(tool.command ?? ""), ...namedReferences(tool.output ?? "")]
        : [],
    );
  rowCache.set(row, named);
  return named;
}

/** What the transcript named up to a row (each row by its place: ReferenceScopeCache `base`): where it named each number, each repository by its
 *  lowercase name (its first spelling; the map's order is the order they were last named), each turn's own numbers
 *  and where it starts, by the id of the prompt that opened it ("" before the first), and the turn
 *  open at that row. A copy shares arrays and maps with its source, so they are replaced, never
 *  changed, except the open turn's, which `copy` copies. */
type Reading = {
  mentions: Map<number, readonly Mention[]>;
  repos: Map<string, Mention>;
  smallest: Map<string, number>;
  /// Persistent (layeredMap.ts), so a copy of a reading costs the open turn, not every turn.
  turns: LayeredMap<{ at: number; named: Map<number, string> }>;
  turn: string;
};

/** Kept between renders. A streaming reply changes only the transcript's last row, so the reading
 *  of every row before it is kept (`prefix`) and only the last row is parsed again; each row
 *  before it costs one pointer comparison. `rowTurn` is each row's turn by its id. The scopes
 *  drawn last are kept too, so a transcript that names nothing new keeps every row's scope object
 *  (a new one re-renders the row). */
export type ReferenceScopeCache = {
  source?: readonly object[];
  prefix?: Reading;
  prefixLength: number;
  /// The reading of the rows before the last prompt the prefix read (`at`): a row of the last turn
  /// that changes (a streamed reply above the live line) reads again from there, not from row 0.
  /// Its maps are its own: the prefix is read on over a copy of it.
  turnStart?: { at: number; reading: Reading };
  generation: number;
  rowTurn: Map<string, string>;
  evidence?: { key: string; value: ReferenceEvidence };
  scopes: Map<string, { key: string; scope: ReferenceScope }>;
  /// Row `i`'s place is `i + base`, the number the readings keep for it (a mention's and a turn's
  /// `at`). A page of older history above the first row lowers it by the page's rows, so every row
  /// read before keeps its place, and the page is read alone and put in front (`inFront`): the
  /// reading of a page costs the page, not the chat (bench/transcript-render-scale.bench.ts).
  base: number;
  /// The pages put in front, newest last, with what the reading was before each: a page taken away
  /// again (and nothing read since) puts it back.
  pages: Page[];
};

/// A page put in front of the reading (ReferenceScopeCache `pages`).
type Page = {
  count: number;
  /// The prefix it made, and the prefix and turn start before it.
  after: Reading;
  prefix: Reading;
  turnStart?: { at: number; reading: Reading };
  /// The rows after it, before their first prompt, that its open turn took (their turn was "").
  led: readonly string[];
};

/// The most pages kept to take away again.
const MAX_PAGES = 8;

export const newReferenceScopeCache = (): ReferenceScopeCache => ({
  prefixLength: 0,
  generation: 0,
  rowTurn: new Map(),
  scopes: new Map(),
  base: 0,
  pages: [],
});

/// Where the turn before the first prompt starts: before every place.
const BEFORE_FIRST = -Infinity;

const empty = (): Reading => ({
  mentions: new Map(),
  repos: new Map(),
  smallest: new Map(),
  turns: LayeredMap.empty(),
  turn: "",
});

const copy = (reading: Reading): Reading => {
  const open = reading.turns.get(reading.turn);
  const turns = open
    ? reading.turns.with(new Map([[reading.turn, { at: open.at, named: new Map(open.named) }]]))
    : reading.turns;
  return {
    mentions: new Map(reading.mentions),
    repos: new Map(reading.repos),
    smallest: new Map(reading.smallest),
    turns,
    turn: reading.turn,
  };
};

function read(reading: Reading, row: Pick<AcpmuxRow, "id" | "kind" | "text" | "items">, at: number) {
  if (row.kind === "user") {
    reading.turn = row.id;
    reading.turns = reading.turns.with(new Map([[row.id, { at, named: new Map() }]]));
  }
  for (const { number, repo } of rowNamed(row)) {
    const key = repo.toLowerCase();
    const spelled = reading.repos.get(key)?.repo ?? repo;
    // Deleted first, so the map's order is the order the repositories were last named, in a row too.
    reading.repos.delete(key);
    reading.repos.set(key, { repo: spelled, at });
    if (number === undefined) continue;
    if (!(number >= (reading.smallest.get(key) ?? Infinity))) reading.smallest.set(key, number);
    reading.mentions.set(number, [...(reading.mentions.get(number) ?? []), { at, repo: spelled }]);
    if (!reading.turns.has(reading.turn))
      reading.turns = reading.turns.with(new Map([[reading.turn, { at: BEFORE_FIRST, named: new Map() }]]));
    reading.turns.get(reading.turn)!.named.set(number, spelled);
  }
}

/** The reading of `page`'s rows followed by `rest`'s, each read alone, `page`'s at places before
 *  `rest`'s: the reading of both from the first row. Costs what `page` named, the numbers and
 *  repositories `rest` named (copied maps) and `rest`'s rows before its first prompt: never `rest`'s
 *  rows. Undefined where a repository `page` names first is spelled otherwise in `rest` (its
 *  first spelling would change in every turn of `rest`): read from the first row then. */
function inFront(page: Reading, rest: Reading): Reading | undefined {
  for (const [key, { repo }] of page.repos) {
    const later = rest.repos.get(key);
    if (later && later.repo !== repo) return undefined;
  }
  const mentions = new Map(rest.mentions);
  for (const [number, list] of page.mentions) mentions.set(number, [...list, ...(rest.mentions.get(number) ?? [])]);
  // Last named last: the repositories `rest` names were named after every one `page` names.
  const repos = new Map<string, Mention>();
  for (const [key, mention] of page.repos) if (!rest.repos.has(key)) repos.set(key, mention);
  for (const [key, mention] of rest.repos) repos.set(key, mention);
  const smallest = new Map(rest.smallest);
  for (const [key, number] of page.smallest)
    if (!(number >= (smallest.get(key) ?? Infinity))) smallest.set(key, number);
  // `rest`'s rows before its first prompt were read in the turn before the first ("") and are in
  // `page`'s open turn. The open turn is its own map: a reading reads on into it.
  const changes = new Map<string, { at: number; named: Map<number, string> } | undefined>();
  for (const key of page.turns.keys()) changes.set(key, page.turns.get(key));
  const lead = rest.turns.get("");
  const open = page.turns.get(page.turn);
  if (lead || (open && !rest.turn)) {
    const named = new Map(open?.named ?? []);
    for (const [number, repo] of lead?.named ?? []) named.set(number, repo);
    changes.set(page.turn, { at: open?.at ?? BEFORE_FIRST, named });
    if (page.turn !== "" && lead && !page.turns.has("")) changes.set("", undefined);
  }
  return { mentions, repos, smallest, turns: rest.turns.with(changes), turn: rest.turn || page.turn };
}

/** The scope of each turn, by the id of the prompt that opened it. `source` is the client's rows,
 *  which still hold the work a closed "Worked for" folds away and the prompts it hides
 *  (conversation/turns.ts). A turn starts at each prompt (an agent's message is one). */
export function referenceScopes(
  source: readonly ReadRow[],
  cache: ReferenceScopeCache = newReferenceScopeCache(),
): (opener: string) => ReferenceScope {
  // The kept reading stands when every row it read is still the same object at the same place
  // (rowsDelta.ts: found once for the transcript's passes, and told by the rows' maker).
  const delta = cache.prefix && cache.source ? rowsDelta(cache.source, source) : undefined;
  // A page of older history above the first row, or the last one taken away again: the rows read
  // before keep their places (`base`), and only the page is read.
  const paged = delta && (inFrontOf(cache, source, delta) || takenAway(cache, source, delta));
  const same = paged ? source.length : delta ? delta.from : -1;
  let kept = source.length > cache.prefixLength && same >= cache.prefixLength;
  // A changed row of the last turn the prefix read (a streamed reply with the live line under it)
  // reads again from that turn's prompt, over a copy of the reading before it: the same reading as
  // one from row 0, as a new generation, for the rows of one turn.
  const restartAt = cache.turnStart ? cache.turnStart.at - cache.base : -1;
  const restart =
    !kept && cache.turnStart && same >= restartAt && source.length > restartAt ? cache.turnStart : undefined;
  if (!kept) {
    cache.generation += 1;
    if (!restart) {
      cache.rowTurn.clear();
      cache.turnStart = undefined;
      cache.base = 0;
      cache.pages = [];
    }
  }
  const last = source.length - 1;
  // The kept reading is only read from when no row before the last is new: copied only when the
  // loop below reads more into it (a copy is O(numbers named), once per snapshot).
  const reading = kept
    ? cache.prefixLength < last
      ? copy(cache.prefix!)
      : cache.prefix!
    : restart
      ? copy(restart.reading)
      : empty();
  if (restart) kept = true;
  const start = restart ? restartAt : kept ? cache.prefixLength : 0;
  // The last prompt this pass reads, whose reading before it is kept (`turnStart`): found from the
  // end, over the last turn's rows.
  let lastPrompt = last - 1;
  while (lastPrompt >= start && source[lastPrompt]!.kind !== "user") lastPrompt -= 1;
  for (let index = start; index < last; index++) {
    // A restart from that prompt keeps the reading it started from.
    if (index === lastPrompt && index !== (restart ? restartAt : -1))
      cache.turnStart = { at: index + cache.base, reading: copy(reading) };
    read(reading, source[index]!, index + cache.base);
    cache.rowTurn.set(source[index]!.id, reading.turn);
  }
  cache.source = source;
  cache.prefix = reading;
  cache.prefixLength = Math.max(0, last);
  // The last row read over a copy, unless reading it changes nothing (no prompt, nothing named: a
  // running call's output that names no pull request), so a snapshot copies no reading.
  const lastRow = last >= 0 ? source[last]! : undefined;
  const changes = lastRow !== undefined && (lastRow.kind === "user" || rowNamed(lastRow).length > 0);
  const whole = changes ? copy(reading) : reading;
  if (lastRow) {
    if (changes) read(whole, lastRow, last + cache.base);
    cache.rowTurn.set(lastRow.id, whole.turn);
  }
  // The prefix's reading changes only with a new generation or a longer prefix; the last row is
  // the rest of what the evidence depends on.
  const tail = last >= 0 ? `${source[last]!.kind}:${JSON.stringify(rowNamed(source[last]!))}` : "";
  const evidenceKey = `${cache.generation}:${cache.prefixLength}:${tail}`;
  if (cache.evidence?.key !== evidenceKey) {
    const linked = [...whole.repos.values()].map(({ repo }) => repo).reverse();
    cache.evidence = { key: evidenceKey, value: { mentions: whole.mentions, linked, smallest: whole.smallest } };
    cache.scopes.clear();
  }
  const evidence = cache.evidence.value;
  if (cache.scopes.size > MAX_KEPT_TURNS) cache.scopes.clear();
  return (opener) => {
    const turn = whole.turns.get(opener) ?? { at: BEFORE_FIRST, named: NONE };
    const key = `${turn.at}:${JSON.stringify([...turn.named])}`;
    const scope = cache.scopes.get(opener);
    if (scope?.key === key) return scope.scope;
    const next = { evidence, turn: turn.named, at: turn.at };
    cache.scopes.set(opener, { key, scope: next });
    return next;
  };
}

/** `delta` without the rows at the end of its change that read alike (`readsAlike`): a row the
 *  change made again at the same place after its rows (the first turn's rows, shaped again under
 *  a page above them) is read as the row it replaced. O(rows changed). */
function readAlike(
  before: readonly ReadRow[],
  source: readonly ReadRow[],
  delta: RowsDelta,
): { from: number; end: number; baseEnd: number } {
  let { end, baseEnd } = delta;
  while (end > delta.from && baseEnd > delta.from && readsAlike(before[baseEnd - 1]!, source[end - 1]!)) {
    end -= 1;
    baseEnd -= 1;
  }
  return { from: delta.from, end, baseEnd };
}

/** Two rows the reading reads the same from: the same id and kind, naming the same repositories. */
function readsAlike(a: ReadRow, b: ReadRow): boolean {
  if (a === b) return true;
  if (a.id !== b.id || a.kind !== b.kind) return false;
  const named = rowNamed(a);
  const other = rowNamed(b);
  return (
    named.length === other.length &&
    named.every((each, at) => each.repo === other[at]!.repo && each.number === other[at]!.number)
  );
}

/** A row the reading reads nothing from: no prompt, nothing named. */
const inert = (row: ReadRow) => row.kind !== "user" && rowNamed(row).length === 0;

/** `source` is the rows the cache read with a page above them (`delta`: every row kept after it):
 *  the page is read alone, at the places before the first row's, and put in front of the prefix
 *  and the turn start (`inFront`). Whether it was. */
function inFrontOf(cache: ReferenceScopeCache, source: readonly ReadRow[], changed: RowsDelta): boolean {
  const before = cache.source! as readonly ReadRow[];
  const delta = readAlike(before, source, changed);
  const count = delta.end;
  if (delta.from !== 0 || count === 0 || count >= source.length || delta.baseEnd >= before.length) return false;
  if (cache.prefixLength !== before.length - 1) return false;
  // The rows it took the place of (the first row's date line, drawn again over the page) read as
  // nothing: the reading of the rows after them is the reading without them.
  for (let index = 0; index < delta.baseEnd; index++) if (!inert(before[index]!)) return false;
  const base = cache.base + delta.baseEnd - count;
  const page = empty();
  const turns: string[] = [];
  for (let index = 0; index < count; index++) {
    read(page, source[index]!, index + base);
    turns.push(page.turn);
  }
  const prefix = inFront(page, cache.prefix!);
  const turnStart = cache.turnStart && inFront(page, cache.turnStart.reading);
  if (!prefix || (cache.turnStart && !turnStart)) return false;
  for (let index = 0; index < delta.baseEnd; index++) cache.rowTurn.delete(before[index]!.id);
  for (let index = 0; index < count; index++) cache.rowTurn.set(source[index]!.id, turns[index]!);
  // The rows read before the first prompt after the page are in the page's open turn.
  const led: string[] = [];
  if (page.turn !== "")
    for (let index = count; index < source.length && source[index]!.kind !== "user"; index++) {
      const id = source[index]!.id;
      if (cache.rowTurn.get(id) !== "") continue;
      cache.rowTurn.set(id, page.turn);
      led.push(id);
    }
  cache.pages.push({ count, after: prefix, prefix: cache.prefix!, turnStart: cache.turnStart, led });
  if (cache.pages.length > MAX_PAGES) cache.pages.shift();
  cache.prefix = prefix;
  cache.turnStart = cache.turnStart && { at: cache.turnStart.at, reading: turnStart! };
  cache.prefixLength += count - delta.baseEnd;
  cache.base = base;
  cache.source = source;
  cache.generation += 1;
  return true;
}

/** `source` is the rows the cache read without the last page put in front (and nothing read
 *  since): the reading before it stands again. Whether it was. */
function takenAway(cache: ReferenceScopeCache, source: readonly ReadRow[], changed: RowsDelta): boolean {
  const page = cache.pages.at(-1);
  const before = cache.source! as readonly ReadRow[];
  const delta = readAlike(before, source, changed);
  if (!page || cache.prefix !== page.after || delta.from !== 0 || delta.baseEnd !== page.count) return false;
  if (delta.end >= source.length) return false;
  // Rows that read as nothing may come back in its place (the first row's date line).
  for (let index = 0; index < delta.end; index++) if (!inert(source[index]!)) return false;
  for (let index = 0; index < page.count; index++) cache.rowTurn.delete((before[index] as ReadRow).id);
  for (const id of page.led) cache.rowTurn.set(id, "");
  for (let index = 0; index < delta.end; index++) cache.rowTurn.set(source[index]!.id, "");
  cache.pages.pop();
  cache.prefix = page.prefix;
  cache.turnStart = page.turnStart;
  cache.prefixLength += delta.end - page.count;
  cache.base += page.count - delta.end;
  cache.source = source;
  cache.generation += 1;
  return true;
}

/** The id of the prompt that opened the turn drawn row `rows[index]` is in: its own row's (an
 *  edit card drawn again under "Worked for" is `<id>:fold`), else that of the nearest row above
 *  it that came from the client (a "Worked for" line, a date or a footer is the pane's own). */
export function turnOpener(cache: ReferenceScopeCache, rows: readonly Pick<AcpmuxRow, "id">[], index: number): string {
  for (let at = index; at >= 0; at--) {
    const turn = cache.rowTurn.get(rows[at]!.id.replace(/:fold$/, ""));
    if (turn !== undefined) return turn;
  }
  return "";
}

const NONE: ReadonlyMap<number, string> = new Map();
/** Turns of chats this view drew before, kept no longer than this. */
const MAX_KEPT_TURNS = 4_000;

/** Rules a and b: the repository the transcript names for `number`, else undefined. */
export function namedRepository(number: number, scope: ReferenceScope | null): string | undefined {
  if (!scope) return undefined;
  const own = scope.turn.get(number);
  if (own) return own;
  const mentions = scope.evidence.mentions.get(number) ?? [];
  let before: string | undefined;
  for (const mention of mentions) if (mention.at < scope.at) before = mention.repo;
  return before;
}

/** Rule 4: whether `number` is as long as every number the chat named in `repo`; a repository
 *  the chat named no number in has no range, so any number is in it. */
export function inNamedRange(number: number, repo: string, scope: ReferenceScope | null): boolean {
  const smallest = scope?.evidence.smallest.get(repo.toLowerCase());
  return smallest === undefined || String(number).length >= String(smallest).length;
}

/** Rule c's candidates: `fallback` (rule d's) first, then the chat's repositories, latest first,
 *  each only if `number` is in its range (rule 4). */
export function candidateRepositories(fallback: string, scope: ReferenceScope | null, number: number): string[] {
  const out = [fallback];
  for (const repo of scope?.evidence.linked ?? []) {
    if (out.length >= MAX_CANDIDATES) break;
    if (!out.some((kept) => kept.toLowerCase() === repo.toLowerCase())) out.push(repo);
  }
  return out.filter((repo) => inNamedRange(number, repo, scope));
}

/** Rules c and d: the first candidate with pull request N, and the others that have it too;
 *  `existing` is undefined (or has none) until the cache answers, and then rule d stands when
 *  `fallback` (the folder's repository) is still a candidate; without it, N is text. */
export function chooseRepository(
  candidates: readonly string[],
  existing: readonly boolean[] | undefined,
  fallback = candidates[0],
): { repository: string; alternatives: string[] } | undefined {
  const found = existing ? candidates.filter((_, index) => existing[index]) : [];
  if (found.length) return { repository: found[0]!, alternatives: found.slice(1) };
  return fallback !== undefined && candidates[0] === fallback ? { repository: fallback, alternatives: [] } : undefined;
}
