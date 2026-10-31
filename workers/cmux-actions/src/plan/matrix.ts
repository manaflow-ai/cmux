/**
 * Matrix expansion with GitHub's include/exclude rules:
 * https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations
 *
 * 1. The cartesian product of every key except include/exclude, in key order.
 * 2. Exclude removes each combination that matches all keys of an entry.
 * 3. Each include entry is added to every original combination whose original
 *    keys it does not contradict (added keys may be overwritten later). If it
 *    fits no original combination it becomes a new combination.
 */

import { isArray, isObject, type Value, type ValueObject } from "../expr/value.ts";

export class MatrixError extends Error {
  override readonly name = "MatrixError";
}

export const MAX_MATRIX_JOBS = 256;

export type Combination = Readonly<Record<string, Value>>;

const deepEqual = (a: Value, b: Value): boolean => {
  if (a === b) return true;
  if (isArray(a) && isArray(b)) return a.length === b.length && a.every((item, index) => deepEqual(item, b[index] ?? null));
  if (isObject(a) && isObject(b)) {
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && deepEqual(a[key] ?? null, b[key] ?? null));
  }
  return false;
};

const entries = (value: Value | undefined, name: string): ValueObject[] => {
  if (value === undefined || value === null) return [];
  if (!isArray(value)) throw new MatrixError(`matrix.${name} must be a list`);
  return value.map((item) => {
    if (!isObject(item)) throw new MatrixError(`matrix.${name} entries must be mappings`);
    return item;
  });
};

/** Expands an evaluated `strategy.matrix`. Returns null when the job has no matrix. */
export const expandMatrix = (matrix: Value): Combination[] | null => {
  if (matrix === null) return null;
  if (!isObject(matrix)) throw new MatrixError("strategy.matrix must be a mapping");
  const include = entries(matrix.include, "include");
  const exclude = entries(matrix.exclude, "exclude");
  const keys = Object.keys(matrix).filter((key) => key !== "include" && key !== "exclude");

  let base: Array<Record<string, Value>> = keys.length === 0 ? [] : [{}];
  for (const key of keys) {
    const values = matrix[key] ?? null;
    if (!isArray(values)) throw new MatrixError(`matrix.${key} must be a list`);
    const next: Array<Record<string, Value>> = [];
    for (const combination of base) for (const value of values) next.push({ ...combination, [key]: value });
    base = next;
  }

  base = base.filter(
    (combination) =>
      !exclude.some((entry) => Object.entries(entry).every(([key, value]) => deepEqual(combination[key] ?? null, value))),
  );

  const original = new Set(keys);
  const added: Array<Record<string, Value>> = [];
  for (const entry of include) {
    let matched = false;
    for (const combination of base) {
      const fits = Object.entries(entry).every(
        ([key, value]) => !original.has(key) || deepEqual(combination[key] ?? null, value),
      );
      if (!fits) continue;
      matched = true;
      for (const [key, value] of Object.entries(entry)) if (!original.has(key)) combination[key] = value;
    }
    if (!matched) added.push({ ...entry });
  }

  const all = [...base, ...added];
  if (all.length === 0) throw new MatrixError("matrix produced no combinations");
  if (all.length > MAX_MATRIX_JOBS) throw new MatrixError(`matrix produced ${all.length} jobs; the limit is ${MAX_MATRIX_JOBS}`);
  return all;
};
