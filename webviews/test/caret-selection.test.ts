// Pages draw the caret and selected text in the Ghostty config's colors (cx-wqn5): every caret
// reads `--cmux-caret` (the cursor color, WebTheme.swift) and every selection
// `--cmux-text-selection` (the config's `selection-background` or `appearance.highlightColor`, else the derived text-field color), so a
// config edit reaches them in place. A caret in another themed color (the shell mode's accent)
// carries a `caret-color: <reason>` comment on its line.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function files(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return /^(gallery|prototype)$/.test(entry.name) ? [] : files(full);
    return entry.name.endsWith(".css") && !entry.name.endsWith(".gallery.css") ? [full] : [];
  });
}

/** Each declaration of `property` in the page stylesheets, with where it is. */
function declarations(property: string, selector?: RegExp) {
  const found: Array<{ at: string; value: string; line: string }> = [];
  for (const file of files(SRC)) {
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split("\n");
    const rule = new RegExp(`([^{}]*)\\{([^{}]*)\\}`, "g");
    for (const match of text.matchAll(rule)) {
      if (selector && !selector.test(match[1])) continue;
      const body = match[2];
      const offset = (match.index ?? 0) + match[1].length;
      for (const decl of body.matchAll(new RegExp(`(?:^|[;\\s])${property}\\s*:\\s*([^;}]+)`, "g"))) {
        const lineNumber = text.slice(0, offset + (decl.index ?? 0) + 1).split("\n").length;
        const at = `${path.relative(SRC, file)}:${lineNumber}`;
        found.push({ at, value: decl[1].trim(), line: lines[lineNumber - 1] ?? "" });
      }
    }
  }
  return found;
}

const markdownDefaults = fs.readFileSync(path.join(SRC, "pages/markdown/settings.ts"), "utf8");

describe("carets and selections follow the Ghostty config", () => {
  test("every caret reads the cursor color", () => {
    const wrong = declarations("caret-color")
      .filter(({ value, line }) => value !== "transparent" && !/caret-color:\s*\S/.test(line.replace(/^[^/]*/, "")))
      .filter(({ value }) => !value.includes("--cmux-caret") && value !== "var(--cmux-md-caret-color)")
      .map(({ at, value }) => `${at} ${value}`);
    expect(wrong).toEqual([]);
  });

  test("every selection reads the config's selection color", () => {
    const wrong = declarations("background(?:-color)?", /::selection/)
      .filter(({ value }) => value !== "transparent")
      .filter(({ value }) => !value.includes("--cmux-text-selection") && value !== "var(--cmux-md-selection-color)")
      .map(({ at, value }) => `${at} ${value}`);
    expect(wrong).toEqual([]);
  });

  test("the Markdown page's own caret and selection default to them", () => {
    const value = (name: string) => markdownDefaults.match(new RegExp(`"${name}":\\s*"([^"]*)"`))?.[1];
    expect(value("--cmux-md-caret-color")).toContain("--cmux-caret");
    expect(value("--cmux-md-selection-color")).toContain("--cmux-text-selection");
  });
});
