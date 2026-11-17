// Every browser a bench launches comes from bench/browsers.ts, so every Chromium launch runs the Chrome the perf runner
// installed (scripts/ci/ensure-system-chrome.sh), never Playwright's own Chromium, which the runner does not install.
// ui-stability launched it directly and failed every perf cron run with "Executable doesn't exist" (run 43326639123);
// six more benches did the same, and sixteen others copied the CMUX_CHROME_HEADLESS_SHELL choice by hand.
// This scan is the detector for that class: a bench file that imports a value from "playwright" (types are fine) or
// reads CMUX_CHROME_HEADLESS_SHELL itself fails here.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const BENCH = path.resolve(import.meta.dir, "../bench");
const HELPER = "browsers.ts";

/// The lines of `source` that get a browser some way other than bench/browsers.ts (pure).
function directLaunches(source: string): string[] {
  const found: string[] = [];
  const imports = /import\s+(type\s+)?([^;]*?)\s+from\s+["'](playwright(?:-core)?)["']/g;
  for (const match of source.matchAll(imports)) {
    if (match[1]) continue;
    const clause = match[2] ?? "";
    const named = /^\{([^}]*)\}$/.exec(clause.trim());
    const values = named
      ? (named[1] ?? "")
          .split(",")
          .map((name) => name.trim())
          .filter((name) => name && !name.startsWith("type "))
      : [clause.trim()];
    if (values.length) found.push(match[0].replace(/\s+/g, " "));
  }
  for (const match of source.matchAll(/(?:require|import)\(\s*["']playwright(?:-core)?["']\s*\)/g))
    found.push(match[0]);
  for (const match of source.matchAll(/.*CMUX_CHROME_HEADLESS_SHELL.*/g)) found.push(match[0].trim());
  return found;
}

function benchFiles(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return benchFiles(full);
    return /\.(?:[cm]?[jt]sx?)$/.test(entry.name) ? [full] : [];
  });
}

describe("bench browser launches", () => {
  test("the scan flags a direct import, a require and a hand-copied shell choice, not a type import", () => {
    expect(directLaunches('import { chromium, type Page } from "playwright";')).toHaveLength(1);
    expect(directLaunches('import { webkit } from "playwright-core";')).toHaveLength(1);
    expect(directLaunches('import playwright from "playwright";')).toHaveLength(1);
    expect(directLaunches('const { chromium } = require("playwright");')).toHaveLength(1);
    expect(directLaunches('await import("playwright")')).toHaveLength(1);
    expect(directLaunches("executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL")).toHaveLength(1);
    expect(directLaunches('import type { Browser, Page } from "playwright";')).toEqual([]);
    expect(directLaunches('import { type Page } from "playwright";')).toEqual([]);
    expect(directLaunches('import { chromium, webkit } from "./browsers";')).toEqual([]);
  });

  test("every bench gets its browsers from bench/browsers.ts", () => {
    const offenders = benchFiles(BENCH)
      .filter((file) => path.relative(BENCH, file) !== HELPER)
      .flatMap((file) =>
        directLaunches(fs.readFileSync(file, "utf8")).map((line) => `${path.relative(BENCH, file)}: ${line}`),
      );
    expect(offenders).toEqual([]);
  });
});
