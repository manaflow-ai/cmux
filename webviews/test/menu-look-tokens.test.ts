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

  // A rule added only to wrap a token (glass.css `.ui-popup.ui-glass`) re-declares a property an
  // earlier rule for the same selector already sets; its fallback must be that value, or a base change
  // to the earlier rule (cmux#47046's merge: popups' --host-glass-fill went transparent) is silently
  // undone for every person with no look installed.
  test("a token's fallback equals the value an earlier rule for the same selector sets", () => {
    const mismatches: string[] = [];
    for (const { file, text } of sheets) {
      const rules = [...text.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((match) => ({
        // A comma inside :not(...) or :is(...) is part of one selector, not a list separator.
        selectors: match[1].split(/,(?![^(]*\))/).map((s) => s.trim().replace(/\s+/g, " ")),
        decls: new Map(
          match[2]
            .split(/;(?![^(]*\))/)
            .map((decl) => decl.split(/:(.*)/s).map((part) => part?.trim()))
            .filter(([prop, value]) => prop && value)
            .map(([prop, value]) => [prop, value.replace(/\s+/g, " ")] as [string, string]),
        ),
      }));
      rules.forEach((rule, index) => {
        for (const [prop, value] of rule.decls) {
          const fallback = tokenFallback(value);
          if (fallback === undefined) continue;
          for (const selector of rule.selectors) {
            const earlier = rules
              .slice(0, index)
              .filter((other) => other.selectors.includes(selector) && other.decls.has(prop))
              .at(-1);
            if (earlier && earlier.decls.get(prop) !== fallback)
              mismatches.push(
                `${file}: ${selector} ${prop}: falls back to ${fallback}, earlier ${earlier.decls.get(prop)}`,
              );
          }
        }
      });
    }
    expect(mismatches).toEqual([]);
  });
});

/** `var(--menu-x, F)` as a whole value: F, else undefined. */
function tokenFallback(value: string): string | undefined {
  const head = /^var\(\s*--menu-[\w-]+\s*,/.exec(value);
  if (!head || !value.endsWith(")")) return undefined;
  let depth = 0;
  for (let i = 3; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")" && --depth === 0)
      return i === value.length - 1 ? value.slice(head[0].length, -1).trim() : undefined;
  }
  return undefined;
}
