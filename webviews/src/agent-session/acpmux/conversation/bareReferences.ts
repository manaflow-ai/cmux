// Which repository a bare `#N` in the transcript means (Leo 2026-10-22: "in a nother chat it kept
// only linking to leo-workspace and not the cmux repo"). A coordinator chat whose folder is
// leo-workspace writes cmux pull request numbers, and reading every bare `#N` as the folder's
// linked each one to the wrong repository. Strongest evidence first:
//
// 1. `owner/repo#N` and a GitHub address name their own repository (githubReferences.ts).
// 2. A bare `#N` takes
//    a. the repository its own turn names for N: `manaflow-ai/cmux#24175` or its address, in the
//       prompt or agent message that opened the turn, a reply, or a command and its output;
//    b. else the repository the chat last named N with, anywhere in the transcript;
//    c. else the candidate that has pull request N, as the App's pull request cache says
//       (chips/referenceExistence.ts): the folder's repository, then the ones the chat linked;
//    d. else the folder's repository (or the transcript's, transcriptRepositories.ts).
// 3. A number that is a pull request in two or more candidates names its repository on the chip
//    (`leo-workspace#843`).
import { createContext } from "react";
import { githubReferences } from "../../../githubReferences";
import type { AcpmuxRow } from "../model";

/** What the whole transcript says, shared by every row. */
export type ReferenceEvidence = {
  /** Rule b: each number's repository, as the chat last named it. */
  named: ReadonlyMap<number, string>;
  /** Rule c's candidates after the folder's: the repositories the chat named, latest first. */
  linked: readonly string[];
};

/** A row's evidence: the transcript's, and its own turn's (rule a). */
export type ReferenceScope = {
  evidence: ReferenceEvidence;
  turn: ReadonlyMap<number, string>;
};

/** The row a chip draws in (App.tsx VirtualTranscript); null outside a transcript. */
export const ReferenceScopeContext = createContext<ReferenceScope | null>(null);

/** The most candidates rule c asks about for one number, the folder's included. */
export const MAX_CANDIDATES = 3;

type Named = { number: number; repo: string };

// A pull request's or issue's address; the repository's own `.git` suffix is not its name.
const ADDRESS =
  /(?<![\w.-])(?:https?:\/\/)?(?:www\.)?github\.com\/([A-Za-z0-9][\w.-]*\/[A-Za-z0-9][\w.-]*?)(?:\.git)?\/(?:pull|issues)\/([1-9][0-9]{0,9})(?![0-9])/g;

/** Every number `text` names with its repository: addresses, `owner/repo#N` and `hq#N`. */
export function namedReferences(text: string): Named[] {
  if (!text.includes("#") && !text.includes("github.com")) return [];
  const out: Named[] = [];
  for (const match of text.matchAll(ADDRESS)) out.push({ number: Number(match[2]), repo: match[1]! });
  for (const ref of githubReferences(text, undefined, "pull", true)) {
    const address = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)$/.exec(ref.href);
    if (address) out.push({ number: Number(address[2]), repo: address[1]! });
  }
  return out;
}

/** Each row's named numbers, for the row object they were read from. */
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

/** What the transcript named up to a row: each number's repository, each repository by its
 *  lowercase name (its first spelling and the row that last named it), each turn's own numbers by
 *  the id of the prompt that opened it ("" before the first), and the turn open at that row. */
type Reading = {
  named: Map<number, string>;
  repos: Map<string, { repo: string; at: number }>;
  turns: Map<string, Map<number, string>>;
  turn: string;
};

/** Kept between renders. A streaming reply changes only the transcript's last row, so the reading
 *  of every row before it is kept (`prefix`) and only the rows after it are read again: no work
 *  per token for each row of the transcript. The scopes drawn last are kept too, so a transcript
 *  that names nothing new keeps every row's scope object (a new one re-renders the row). */
export type ReferenceScopeCache = {
  source?: readonly object[];
  prefix?: Reading;
  prefixLength: number;
  evidence?: { key: string; value: ReferenceEvidence };
  scopes: Map<string, { key: string; scope: ReferenceScope }>;
};

export const newReferenceScopeCache = (): ReferenceScopeCache => ({ prefixLength: 0, scopes: new Map() });

/** `reading` with the turn it is in copied, so reading on never writes to the one it came from. */
const copy = (reading: Reading): Reading => {
  const turns = new Map(reading.turns);
  const open = turns.get(reading.turn);
  if (open) turns.set(reading.turn, new Map(open));
  return { named: new Map(reading.named), repos: new Map(reading.repos), turns, turn: reading.turn };
};

function read(reading: Reading, row: Pick<AcpmuxRow, "id" | "kind" | "text" | "items">, index: number) {
  if (row.kind === "user") reading.turn = row.id;
  for (const { number, repo } of rowNamed(row)) {
    const key = repo.toLowerCase();
    const spelled = reading.repos.get(key)?.repo ?? repo;
    reading.repos.set(key, { repo: spelled, at: index });
    reading.named.set(number, spelled);
    if (!reading.turns.has(reading.turn)) reading.turns.set(reading.turn, new Map());
    reading.turns.get(reading.turn)!.set(number, spelled);
  }
}

/** The scope of each turn, by the id of the prompt that opened it. `source` is the client's rows,
 *  which still hold the work a closed "Worked for" folds away (conversation/turns.ts). A turn
 *  starts at each prompt (an agent's message is one). */
export function referenceScopes(
  source: readonly Pick<AcpmuxRow, "id" | "kind" | "text" | "items">[],
  cache: ReferenceScopeCache = newReferenceScopeCache(),
): (opener: string) => ReferenceScope {
  // The kept reading stands when every row it read is still the same object at the same place.
  let kept = Boolean(cache.prefix && cache.source && source.length > cache.prefixLength);
  for (let index = 0; kept && index < cache.prefixLength; index++) kept = source[index] === cache.source![index];
  const reading = kept ? copy(cache.prefix!) : { named: new Map(), repos: new Map(), turns: new Map(), turn: "" };
  for (let index = kept ? cache.prefixLength : 0; index < source.length - 1; index++)
    read(reading, source[index]!, index);
  cache.source = source;
  cache.prefix = reading;
  cache.prefixLength = Math.max(0, source.length - 1);
  const whole = source.length ? copy(reading) : reading;
  if (source.length) read(whole, source[source.length - 1]!, source.length - 1);
  const { named, repos, turns } = whole;
  const linked = [...repos.values()].sort((a, b) => b.at - a.at).map(({ repo }) => repo);
  const evidenceKey = JSON.stringify([[...named], linked]);
  if (cache.evidence?.key !== evidenceKey) {
    cache.evidence = { key: evidenceKey, value: { named, linked } };
    cache.scopes.clear();
  }
  const evidence = cache.evidence.value;
  if (cache.scopes.size > MAX_KEPT_TURNS) cache.scopes.clear();
  return (opener) => {
    const turnNamed = turns.get(opener) ?? NONE;
    const key = JSON.stringify([...turnNamed]);
    const scope = cache.scopes.get(opener);
    if (scope?.key === key) return scope.scope;
    const next = { evidence, turn: turnNamed };
    cache.scopes.set(opener, { key, scope: next });
    return next;
  };
}

/** The id of the prompt that opened the turn `rows[index]` is in ("" before the first). */
export function turnOpener(rows: readonly Pick<AcpmuxRow, "id" | "kind">[], index: number): string {
  for (let at = index; at >= 0; at--) if (rows[at]!.kind === "user") return rows[at]!.id;
  return "";
}

const NONE: ReadonlyMap<number, string> = new Map();
/** Turns of chats this view drew before, kept no longer than this. */
const MAX_KEPT_TURNS = 4_000;

/** Rules a and b: the repository the transcript names for `number`, else undefined. */
export function namedRepository(number: number, scope: ReferenceScope | null): string | undefined {
  return scope?.turn.get(number) ?? scope?.evidence.named.get(number);
}

/** Rule c's candidates: `fallback` (rule d's) first, then the chat's repositories, latest first. */
export function candidateRepositories(fallback: string, scope: ReferenceScope | null): string[] {
  const out = [fallback];
  for (const repo of scope?.evidence.linked ?? []) {
    if (out.length >= MAX_CANDIDATES) break;
    if (!out.some((kept) => kept.toLowerCase() === repo.toLowerCase())) out.push(repo);
  }
  return out;
}

/** Rules c and d: the first candidate with pull request N, and the others that have it too;
 *  `existing` is undefined (or has none) until the cache answers, and then rule d stands. */
export function chooseRepository(
  candidates: readonly string[],
  existing: readonly boolean[] | undefined,
): { repository: string; alternatives: string[] } {
  const found = existing ? candidates.filter((_, index) => existing[index]) : [];
  return found.length
    ? { repository: found[0]!, alternatives: found.slice(1) }
    : { repository: candidates[0]!, alternatives: [] };
}
