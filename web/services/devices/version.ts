/**
 * Dotted-numeric version comparison used by both the server loader and the
 * client dashboard. Keep this module free of server-only imports so it can be
 * bundled into the browser safely.
 */
export function versionBelowFloor(version: string, floor: string): boolean {
  const parse = (value: string): number[] =>
    value.split(".").map((segment) => {
      const numeric = Number.parseInt(segment, 10);
      return Number.isSafeInteger(numeric) && numeric >= 0 ? numeric : 0;
    });
  const have = parse(version);
  const need = parse(floor);
  for (let index = 0; index < Math.max(have.length, need.length); index += 1) {
    const a = have[index] ?? 0;
    const b = need[index] ?? 0;
    if (a !== b) return a < b;
  }
  return false;
}
