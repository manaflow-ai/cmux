// The a11y foundation's rules, enforced (plans/cmux-next/a11y-foundation.md): page code outside
// src/ui has no raw widget roles, tab indexes, key handlers or portals. Files not yet migrated are
// listed in ui-rules.pending.json with their count, which may only go down.
import { describe, expect, test } from "bun:test";
import pendingFile from "./ui-rules.pending.json";
import { counts, scan } from "./ui-rules";

const { "//": _note, ...pending } = pendingFile as Record<string, string | number>;

describe("ui rules", () => {
  const violations = scan();
  const actual = counts(violations);

  test("migrated page code has no raw roles, tab indexes, key handlers or portals", () => {
    const fresh = violations.filter((violation) => !(violation.file in pending));
    expect(
      fresh.map((violation) => `${violation.file}:${violation.line} ${violation.rule}: ${violation.text}`),
    ).toEqual([]);
  });

  test("a pending file never gains violations", () => {
    const grown = Object.entries(actual).filter(([file, count]) => file in pending && count > Number(pending[file]));
    expect(grown.map(([file, count]) => `${file}: ${count} > ${pending[file]}`)).toEqual([]);
  });

  test("the pending list shrinks with the migration (lower a count, delete a clean file)", () => {
    const stale = Object.entries(pending).filter(([file, count]) => (actual[file] ?? 0) < Number(count));
    expect(stale.map(([file, count]) => `${file}: ${actual[file] ?? 0} < ${count}`)).toEqual([]);
  });

  test("the migrated pages stay off the pending list", () => {
    const migrated = Object.keys(pending).filter(
      (file) => file.startsWith("viewer-empty/") || file.startsWith("pages/markdown/"),
    );
    expect(migrated).toEqual([]);
  });
});
