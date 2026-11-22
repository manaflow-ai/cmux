import { describe, expect, it } from "vitest";

// postgres.js serializes a parameter the server types as jsonb with JSON.stringify, so a JSON string passed to
// `$n::jsonb` is stored as a jsonb string, not the object it encodes (src/db/sql.ts). PGlite does not do this, so
// the store tests cannot catch it: on staging every mesh ACL apply failed the document's jsonb_typeof check (23514)
// and every mesh stayed at ACL version 0. Every JSON parameter is cast `$n::text::jsonb`.
const sources = import.meta.glob("../../src/db/*.ts", { query: "?raw", import: "default", eager: true });

describe("store queries", () => {
  it("cast every JSON parameter through text", () => {
    expect(Object.keys(sources).length).toBeGreaterThan(0);
    const offenders = Object.entries(sources).flatMap(([path, text]) =>
      text.split("\n").flatMap((line, index) => (/\$\d+::jsonb/.test(line) ? [`${path}:${index + 1}: ${line.trim()}`] : [])),
    );
    expect(offenders).toEqual([]);
  });
});
