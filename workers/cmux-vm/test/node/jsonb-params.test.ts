import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// postgres.js serializes a parameter the server types as jsonb with JSON.stringify, so a JSON string passed to
// `$n::jsonb` is stored as a jsonb string, not the object it encodes (src/db/sql.ts). PGlite does not do this, so
// the store tests cannot catch it: on staging every mesh ACL apply failed the document's jsonb_typeof check (23514)
// and every mesh stayed at ACL version 0. Every JSON parameter is cast `$n::text::jsonb`.
const DB = join(__dirname, "..", "..", "src", "db");

describe("store queries", () => {
  it("cast every JSON parameter through text", () => {
    const offenders = readdirSync(DB)
      .filter((name) => name.endsWith(".ts"))
      .flatMap((name) =>
        readFileSync(join(DB, name), "utf8")
          .split("\n")
          .flatMap((line, index) => (/\$\d+::jsonb/.test(line) ? [`${name}:${index + 1}: ${line.trim()}`] : [])),
      );
    expect(offenders).toEqual([]);
  });
});
