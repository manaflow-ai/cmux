/// Whether two JSON values (what acpmux sends: objects, arrays, strings, numbers, booleans, null) are
/// the same, whatever the order of their objects' keys. A key whose value is `undefined` counts as
/// absent, as JSON has no such value. Used to tell a summary acpmux sends again unchanged from a change
/// (direct.ts `sessionChanged`), with no string built per comparison.
export function sameJson(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index++) if (!sameJson(a[index], b[index])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  let count = 0;
  for (const key in left) {
    if (!Object.prototype.hasOwnProperty.call(left, key) || left[key] === undefined) continue;
    count++;
    if (!Object.prototype.hasOwnProperty.call(right, key) || !sameJson(left[key], right[key])) return false;
  }
  for (const key in right) if (Object.prototype.hasOwnProperty.call(right, key) && right[key] !== undefined) count--;
  return count === 0;
}
