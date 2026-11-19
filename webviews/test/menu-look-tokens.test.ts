// A look's menu tokens (ui/README.md "Menu tokens a look sets") are off by default: no shipped sheet
// defines one, and every read of one has today's value as its fallback, except the three reads whose
// unset value already leaves the row as it was (an inherited color, a non-inherited opacity's initial 1).
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const src = path.resolve(import.meta.dir, "../src");
const sheets = (fs.readdirSync(src, { recursive: true }) as string[])
  .filter((file) => file.endsWith(".css") && !file.includes(".gallery."))
  .map((file) => ({ file, text: fs.readFileSync(path.join(src, file), "utf8") }));

const readme = fs.readFileSync(path.join(src, "ui/README.md"), "utf8");
const documented = [...readme.matchAll(/^\| `(--menu-[\w-]+)`\s*\|/gm)].map((match) => match[1]);

// `var(--menu-x)` with no fallback, allowed only where unset changes nothing (popupSurface.css).
const bareReads = new Set(["--menu-shortcut-color", "--menu-destructive", "--menu-disabled-opacity"]);

describe("menu look tokens", () => {
  test("the README lists every token", () => {
    expect(documented.length).toBeGreaterThanOrEqual(19);
  });

  test("no shipped sheet sets a token: only a look does", () => {
    const set = sheets.flatMap(({ file, text }) =>
      [...text.matchAll(/(?<![\w(,-])(--menu-[\w-]+)\s*:/g)].map((match) => `${file}: ${match[1]}`),
    );
    expect(set).toEqual([]);
  });

  test("every read has today's value as its fallback", () => {
    const reads = sheets.flatMap(({ file, text }) =>
      [...text.matchAll(/var\(\s*(--menu-[\w-]+)\s*(,)?/g)].map((match) => ({
        file,
        token: match[1],
        fallback: !!match[2],
      })),
    );
    expect(reads.length).toBeGreaterThan(0);
    for (const read of reads) {
      expect({ ...read, documented: documented.includes(read.token) }).toEqual({ ...read, documented: true });
      if (!read.fallback) expect({ ...read, bare: bareReads.has(read.token) }).toEqual({ ...read, bare: true });
    }
  });
});
