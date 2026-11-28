// jsdom has no `CSS`, so a bare `CSS.escape` in page code throws there, and inside an event handler
// the throw is swallowed: #50251's fold click lost its fold hold (transcript-fold-anchor, 48 px of
// drift) and transcript-copy failed the same way (#65355). Page code escapes through src/cssEscape.ts.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { serializeIdentifier } from "../src/cssEscape";

const SRC = join(import.meta.dir, "../src");

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "gallery" ? [] : sources(path);
    return /\.tsx?$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name) ? [path] : [];
  });
}

describe("cssEscape", () => {
  test("page code calls cssEscape, not a bare CSS.escape", () => {
    const bare = sources(SRC)
      .filter((path) => !path.endsWith("/cssEscape.ts"))
      .filter((path) => /\bCSS\.escape\(/.test(readFileSync(path, "utf8")))
      .map((path) => relative(SRC, path));
    expect(bare).toEqual([]);
  });

  test("the fallback serializes like the CSSOM spec", () => {
    expect(serializeIdentifier("row-1")).toBe("row-1");
    expect(serializeIdentifier('a"b\\c')).toBe('a\\"b\\\\c');
    expect(serializeIdentifier(":r1:")).toBe("\\:r1\\:");
    expect(serializeIdentifier("1a")).toBe("\\31 a");
    expect(serializeIdentifier("-1a")).toBe("-\\31 a");
    expect(serializeIdentifier("-")).toBe("\\-");
    expect(serializeIdentifier("a b")).toBe("a\\ b");
    expect(serializeIdentifier("\u0000x")).toBe("�x");
    expect(serializeIdentifier("é")).toBe("é");
  });
});
