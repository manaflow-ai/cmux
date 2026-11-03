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

/** A turn's evidence: the transcript's, its own (rule a), and where it starts. */
export type ReferenceScope = { evidence: ReferenceEvidence; turn: ReadonlyMap<number, string>; at: number };

/** The row a chip draws in (App.tsx VirtualTranscript); null outside a transcript. */
export const ReferenceScopeContext = createContext<ReferenceScope | null>(null);

/** The most candidates rule c asks about for one number, the folder's included. */
export const MAX_CANDIDATES = 3;

type Named = { number?: number; repo: string };

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

/** What the transcript named up to a row: where it named each number, each repository by its
 *  lowercase name (its first spelling; the map's order is the order they were last named), each turn's own numbers
 *  and where it starts, by the id of the prompt that opened it ("" before the first), and the turn
 *  open at that row. A copy shares arrays and maps with its source, so they are replaced, never
 *  changed, except the open turn's, which `copy` copies. */
type Reading = {
  mentions: Map<number, readonly Mention[]>;
  repos: Map<string, Mention>;
  smallest: Map<string, number>;
  turns: Map<string, { at: number; named: Map<number, string> }>;
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
  generation: number;
  rowTurn: Map<string, string>;
  evidence?: { key: string; value: ReferenceEvidence };
  scopes: Map<string, { key: string; scope: ReferenceScope }>;
};

export const newReferenceScopeCache = (): ReferenceScopeCache => ({
  prefixLength: 0,
  generation: 0,
  rowTurn: new Map(),
  scopes: new Map(),
});

const empty = (): Reading => ({
  mentions: new Map(),
  repos: new Map(),
  smallest: new Map(),
  turns: new Map(),
  turn: "",
});

const copy = (reading: Reading): Reading => {
  const turns = new Map(reading.turns);
  const open = turns.get(reading.turn);
  if (open) turns.set(reading.turn, { at: open.at, named: new Map(open.named) });
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
    reading.turns.set(row.id, { at, named: new Map() });
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
    if (!reading.turns.has(reading.turn)) reading.turns.set(reading.turn, { at: 0, named: new Map() });
    reading.turns.get(reading.turn)!.named.set(number, spelled);
  }
}

/** The scope of each turn, by the id of the prompt that opened it. `source` is the client's rows,
 *  which still hold the work a closed "Worked for" folds away and the prompts it hides
 *  (conversation/turns.ts). A turn starts at each prompt (an agent's message is one). */
export function referenceScopes(
  source: readonly Pick<AcpmuxRow, "id" | "kind" | "text" | "items">[],
  cache: ReferenceScopeCache = newReferenceScopeCache(),
): (opener: string) => ReferenceScope {
  // The kept reading stands when every row it read is still the same object at the same place.
  let kept = Boolean(cache.prefix && cache.source && source.length > cache.prefixLength);
  for (let index = 0; kept && index < cache.prefixLength; index++) kept = source[index] === cache.source![index];
  if (!kept) {
    cache.generation += 1;
    cache.rowTurn.clear();
  }
  const reading = kept ? copy(cache.prefix!) : empty();
  const last = source.length - 1;
  for (let index = kept ? cache.prefixLength : 0; index < last; index++) {
    read(reading, source[index]!, index);
    cache.rowTurn.set(source[index]!.id, reading.turn);
  }
  cache.source = source;
  cache.prefix = reading;
  cache.prefixLength = Math.max(0, last);
  const whole = last >= 0 ? copy(reading) : reading;
  if (last >= 0) {
    read(whole, source[last]!, last);
    cache.rowTurn.set(source[last]!.id, whole.turn);
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
    const turn = whole.turns.get(opener) ?? { at: 0, named: NONE };
    const key = `${turn.at}:${JSON.stringify([...turn.named])}`;
    const scope = cache.scopes.get(opener);
    if (scope?.key === key) return scope.scope;
    const next = { evidence, turn: turn.named, at: turn.at };
    cache.scopes.set(opener, { key, scope: next });
    return next;
  };
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
