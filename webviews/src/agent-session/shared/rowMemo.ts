import { experimentArm } from "../../experiments/experiment";
import { cachesBounded, hiddenMeasureCaches } from "../acpmux/hiddenMeasureCaches.experiment";

/// A memo keyed by object, as a WeakMap is, whose table stays bounded however many keys pass
/// through it.
///
/// A WeakMap's table grows to the most entries it held at once and keeps that size after the
/// collector frees them: a chat that grew to 100k rows kept a table sized for every row object
/// made between two collections (1 MB a memo, half of a hidden chat's growth from 4k to 20k
/// rows), though it holds a few thousand rows (Leo, 2026-11-14: "memory and cpu staying flat on
/// infinite chats"). This one writes into a young table and, every `limit` writes, retires it to
/// old and starts a new young one; a key read from old moves to young. So a key read since the
/// last retirement stays, one read in neither generation is computed again, and each table holds
/// `limit` writes at most.
///
/// Only for pure memos: a value computed again must equal the first (`compute` of the same key).
export class RowMemo<K extends object, V> {
  #young = new WeakMap<K, V>();
  #old = new WeakMap<K, V>();
  #writes = 0;
  readonly #limit: number | undefined;

  /// `limit` writes a table; unset, ROW_MEMO_LIMIT (HIDDEN_ROW_MEMO_LIMIT on the
  /// `hidden-measure-caches` experiment's `dropped` arm).
  constructor(limit?: number) {
    this.#limit = limit;
    memos.add(new WeakRef(this as RowMemo<object, unknown>));
    if (!hideHookInstalled) installHideHook();
  }

  /// Forgets every value: both tables start over empty.
  clear(): void {
    this.#young = new WeakMap();
    this.#old = new WeakMap();
    this.#writes = 0;
  }

  get(key: K): V | undefined {
    const young = this.#young.get(key);
    if (young !== undefined || this.#young.has(key)) return young;
    if (!this.#old.has(key)) return undefined;
    const old = this.#old.get(key) as V;
    this.set(key, old);
    return old;
  }

  has(key: K): boolean {
    return this.#young.has(key) || this.#old.has(key);
  }

  set(key: K, value: V): this {
    this.#young.set(key, value);
    if (++this.#writes >= (this.#limit ?? HIDDEN_ROW_MEMO_LIMIT) && this.#writes >= limitNow(this.#limit)) {
      this.#old = this.#young;
      this.#young = new WeakMap();
      this.#writes = 0;
    }
    return this;
  }

  /// The value for `key`, computed once while the key stays in either generation.
  read(key: K, compute: (key: K) => V): V {
    if (this.has(key)) return this.get(key) as V;
    const value = compute(key);
    this.set(key, value);
    return value;
  }
}

/// More than a chat holds at once (direct.ts HELD_RECORDS, 4000 records, makes fewer rows), so the
/// rows one pass reads all stay between two retirements.
export const ROW_MEMO_LIMIT = 8192;

/// On the `hidden-measure-caches` experiment's `dropped` arm: a table's writes, still more than the
/// rows a chat holds at once (direct/heldRecords.ts HELD_RECORDS, 1000 records), and each memo drops
/// both tables when its page hides (a hidden page reads no rows; the shown one computes them again).
/// The default arm keeps ROW_MEMO_LIMIT and the tables. A memo's 8192-entry table was about 0.13 MB,
/// and a hidden 10k-row chat page held 18 of them (cmuxterm-hq goals/chats-flat-at-any-length.md).
export const HIDDEN_ROW_MEMO_LIMIT = 2048;

function limitNow(limit: number | undefined): number {
  if (limit !== undefined) return limit;
  return cachesBounded(experimentArm(hiddenMeasureCaches)) ? HIDDEN_ROW_MEMO_LIMIT : ROW_MEMO_LIMIT;
}

// Every memo of this module copy (each bundle that includes this file has its own copy, its own set
// and its own hide hook), held weakly so a memo made and dropped (a test's) goes.
const memos = new Set<WeakRef<RowMemo<object, unknown>>>();
let hideHookInstalled = false;

/// Clears every memo of this module copy when `doc` is hidden on the `dropped` arm. True when it did.
export function dropRowMemosWhenHidden(doc: Pick<Document, "visibilityState"> | undefined): boolean {
  if (doc?.visibilityState !== "hidden" || !cachesBounded(experimentArm(hiddenMeasureCaches))) return false;
  for (const ref of memos) {
    const memo = ref.deref();
    if (memo) memo.clear();
    else memos.delete(ref);
  }
  return true;
}

function installHideHook(doc: Document | undefined = globalThis.document): void {
  hideHookInstalled = true;
  doc?.addEventListener?.("visibilitychange", () => void dropRowMemosWhenHidden(doc));
}
