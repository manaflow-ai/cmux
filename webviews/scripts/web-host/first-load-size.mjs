#!/usr/bin/env bun
// The web host's first-load size (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, step 3): the gzip -9
// bytes of index.html and of every file it loads before the pane paints (its scripts, modulepreloads
// and stylesheets, `?h=` stripped), as a browser fetches them on a cold visit. English is the locale
// counted (locales/en.js; another language adds its own file).
//
//   bun scripts/web-host/first-load-size.mjs SITE_DIR            # print the measurement as JSON
//   bun scripts/web-host/first-load-size.mjs SITE_DIR --check    # fail past first-load-budget.json
//   bun scripts/web-host/first-load-size.mjs SITE_DIR --report   # warn past it, exit 0 (CI)
//
// CI reports and does not fail: pane.js is the agent pane's bundle, which every webviews change grows,
// so a fixed budget went red on PRs that never touched the web host (2026-11-26: base past the
// 11-25 budget within a day). It turns blocking once the chat path's split gives the web host its own
// first load (cmuxterm-hq docs/rfd/0083-cmux-web-client.md).
//
// SITE_DIR is scripts/cmux-next/build-web-host.sh's output. CI: .github/workflows/cmux-next-size-budget.yml, job web-host.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const BUDGET_FILE = join(import.meta.dir, "first-load-budget.json");

/// The same-site files `html` loads up front, in page order, each once.
export function firstLoadFiles(html) {
  const files = [];
  const tag = /<(script|link)\b([^>]*)>/g;
  for (const [, name, attrs] of html.matchAll(tag)) {
    const attr = (key) => attrs.match(new RegExp(`\\b${key}="([^"]*)"`))?.[1];
    let url;
    if (name === "script") url = attr("src");
    else if (/\b(modulepreload|stylesheet)\b/.test(attr("rel") ?? "")) url = attr("href");
    if (!url || /^[a-z]+:|^\/\//i.test(url)) continue;
    const file = url.replace(/^\//, "").replace(/[?#].*$/, "");
    if (!files.includes(file)) files.push(file);
  }
  return files;
}

export function measure(site) {
  const html = readFileSync(join(site, "index.html"));
  const files = firstLoadFiles(html.toString("utf8"));
  const gzip = (bytes) => gzipSync(bytes, { level: 9 }).length;
  const rows = [{ file: "index.html", raw: html.length, gzip: gzip(html) }];
  for (const file of files) {
    const bytes = readFileSync(join(site, file));
    rows.push({ file, raw: bytes.length, gzip: gzip(bytes) });
  }
  const sum = (key) => rows.reduce((total, row) => total + row[key], 0);
  return { files: rows.length, raw: sum("raw"), gzip: sum("gzip"), rows };
}

if (import.meta.main) {
  const [site, flag] = process.argv.slice(2);
  if (!site) {
    console.error("usage: first-load-size.mjs SITE_DIR [--check]");
    process.exit(2);
  }
  const got = measure(site);
  const largest = [...got.rows].sort((a, b) => b.gzip - a.gzip).slice(0, 5);
  console.log(JSON.stringify({ files: got.files, raw: got.raw, gzip: got.gzip, largest }, null, 2));
  if (flag === "--check" || flag === "--report") {
    const budget = JSON.parse(readFileSync(BUDGET_FILE, "utf8"));
    const kib = (n) => `${(n / 1024).toFixed(1)} KiB`;
    if (got.gzip > budget.gzipBytes) {
      const over =
        `web host first load is ${kib(got.gzip)} gzip, past its budget of ${kib(budget.gzipBytes)} ` +
        `(${BUDGET_FILE}). Make the first load smaller (move code behind a dynamic import), or raise ` +
        `gzipBytes there and say why in the pull request.`;
      if (flag === "--report") {
        console.log(`::warning title=web host first load::${over}`);
        process.exit(0);
      }
      console.error(over);
      process.exit(1);
    }
    console.log(`web host first load ${kib(got.gzip)} gzip, within ${kib(budget.gzipBytes)}`);
  }
}
