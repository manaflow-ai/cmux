// The model picker's search over a catalog of any size (a router's thousands of models): each
// model's search keys are made once, when the picker's catalog is indexed, and a typed key filters
// only what it must. A query that narrows an earlier one (typing on) filters that one's matches; a
// query seen a moment ago (a deleted letter) is the same result again. Matches keep the catalog's
// order, so the first row is the same whichever way the result was reached.
import { acpmuxPerf } from "./perf";
import {
  fitsKeys,
  narrows,
  queryFlatWords,
  searchKeys,
  type ParsedQuery,
  type QueryModel,
  type SearchKeys,
} from "./modelQuery";

export type SearchRow<M, E> = { model: M; entry: E; keys: SearchKeys };

type Result<M, E> = { query: ParsedQuery; rows: readonly SearchRow<M, E>[] };

/// The results kept for a deleted letter or a narrowing query: a query's few last steps.
const HISTORY = 32;

/// Search keys by what they are made of (harness, id, name): a live catalog update makes every
/// model object again, and the index made for it then makes keys only for the models that changed.
/// Bounded; past it, the next index starts it over.
const KEYS_KEPT = 50_000;
const keysKept = new Map<string, SearchKeys>();
function keptKeys(model: QueryModel, harnessName: string): SearchKeys {
  const key = `${harnessName}\u0000${model.id}\u0000${model.name}`;
  let keys = keysKept.get(key);
  if (!keys) {
    if (keysKept.size >= KEYS_KEPT) keysKept.clear();
    keys = searchKeys(model, harnessName);
    keysKept.set(key, keys);
  }
  return keys;
}

export class ModelSearchIndex<M extends QueryModel, E> {
  readonly rows: readonly SearchRow<M, E>[];
  /** Recent results by query, oldest first. */
  private history = new Map<string, Result<M, E>>();

  constructor(entries: readonly E[], models: (entry: E) => readonly M[], harnessName: (entry: E) => string) {
    const rows: SearchRow<M, E>[] = [];
    for (const entry of entries) {
      const name = harnessName(entry);
      for (const model of models(entry)) rows.push({ model, entry, keys: keptKeys(model, name) });
    }
    this.rows = rows;
  }

  /** The rows `query` finds, in catalog order. The same query gives the same array. When none fits
   * and the query ends with an effort or fast word still being typed ("opus 5.5 m" on the way to
   * "medium"), those words wait, as matchingModels does: the rows the rest of the query finds stay. */
  find(query: ParsedQuery): readonly SearchRow<M, E>[] {
    const rows = this.findExact(query);
    if (rows.length > 0 || !query.typing) return rows;
    const { typing, ...rest } = query;
    return this.findExact({ ...rest, words: query.words.slice(0, query.words.length - typing.length) });
  }

  private findExact(query: ParsedQuery): readonly SearchRow<M, E>[] {
    const key = queryKey(query);
    const kept = this.history.get(key);
    if (kept) {
      this.history.delete(key);
      this.history.set(key, kept);
      return kept.rows;
    }
    const start = performance.now();
    // The fewest rows an earlier query found that hold every match of this one.
    let from = this.rows;
    for (const result of this.history.values())
      if (result.rows.length < from.length && narrows(result.query, query)) from = result.rows;
    const flatWords = queryFlatWords(query);
    const rows = from.filter((row) => fitsKeys(row.keys, row.model, query, flatWords));
    this.history.set(key, { query, rows });
    if (this.history.size > HISTORY) this.history.delete(this.history.keys().next().value!);
    recordFilter(performance.now() - start);
    return rows;
  }
}

const queryKey = (query: ParsedQuery) =>
  `${query.effort ?? ""}\u0000${query.fast ? 1 : 0}\u0000${query.words.join("\u0000")}`;

/// Each filter's milliseconds while acpmuxPerf measures (the visible-lists bench reads them).
export const modelFilterTimes: number[] = [];
function recordFilter(ms: number) {
  if (!acpmuxPerf.enabled) return;
  acpmuxPerf.span("modelPicker.filter", ms);
  modelFilterTimes.push(ms);
  if (modelFilterTimes.length > 4096) modelFilterTimes.shift();
}
