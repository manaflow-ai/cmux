// The pages the first window never shows, stored raw-deflated in the app (CMUX-570, app size).
//
//   bun scripts/pages/pack-pages.mjs OUTDIR METAFILE --keep home-channels,... PAGE...
//
// Runs on the pages builder's output (build-pages-web.sh, after each page's index.html is
// written; cwd is webviews/, as for bundle.mjs, so the metafile's paths resolve). Two steps:
//
// 1. Every page outside --keep gets its entry moved from `<page>/app.js` to
//    `__shared/page-<page>.js`, and its index.html imports it from there. Its imports already name
//    `../__shared/...`, which resolves the same from both folders, and no entry names a sibling
//    (`./x`) or reads `import.meta.url`, which the move would change; either fails the build.
// 2. Every `__shared` script that no --keep page loads through static imports alone is replaced by
//    `<name>.js.deflate` (raw DEFLATE, level 9; the same format cmux#45934 stores Shiki's grammars
//    in) when that is smaller. A kept page's dynamic imports (KaTeX, emoji data, the palette, the
//    syntax highlighter, the string-table fallbacks behind the per-locale scripts) are packed too:
//    they load after first paint, when the page first needs them, and are inflated then.
//
// Why `__shared`: both engines ask the app for every file there (Chromium through the `__shared`
// dynamic prefix, FirstPartyPageSchemes; WebKit through PageSchemeHandler), so the app inflates a
// packed file when the page asks for it (PagePackedFile.swift), in memory, and never writes page
// code outside the signed bundle. A page's own folder is read from disk by Chromium's shim, which
// is why the entry moves. The --keep pages (Home and what the first window shows with it) and
// everything they import statically stay as they were: first paint reads no packed byte.
import { deflateRawSync } from "node:zlib";
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";

/** The suffix of a packed file; PagePackedFile.swift and cmux-tui's page_files.rs read it. */
export const PACKED_SUFFIX = ".deflate";
const ENTRY_IMPORT = 'import "./app.js";';
// A string an entry would resolve beside itself: an import of `./x` or `import.meta.url`.
const SIBLING_REFERENCE = /(?:from|import)\s*\(?\s*["']\.\/|import\.meta\.url/;

/** Output path (absolute) to the absolute paths it imports; `staticOnly` leaves out dynamic imports. */
export function importGraph(metafile, cwd = process.cwd(), { staticOnly = false } = {}) {
  const graph = new Map();
  for (const [file, output] of Object.entries(metafile.outputs)) {
    graph.set(
      path.resolve(cwd, file),
      output.imports
        .filter((item) => !item.external && !(staticOnly && item.kind === "dynamic-import"))
        .map((item) => path.resolve(cwd, item.path)),
    );
  }
  return graph;
}

/** Every file reachable from `entries` through `graph`. */
export function reachable(graph, entries) {
  const seen = new Set(entries);
  const queue = [...entries];
  for (let i = 0; i < queue.length; i++) {
    for (const next of graph.get(queue[i]) ?? []) {
      if (seen.has(next)) continue;
      seen.add(next);
      queue.push(next);
    }
  }
  return seen;
}

/** Moves `page`'s entry into `__shared` and points its document at it. */
export function moveEntry(outdir, page) {
  const entry = path.join(outdir, page, "app.js");
  const moved = path.join(outdir, "__shared", `page-${page}.js`);
  const document = path.join(outdir, page, "index.html");
  const source = readFileSync(entry, "utf8");
  if (SIBLING_REFERENCE.test(source)) {
    throw new Error(
      `pack-pages: ${page}/app.js names a file beside itself or import.meta.url; it cannot move to __shared`,
    );
  }
  if (existsSync(moved)) throw new Error(`pack-pages: ${path.relative(outdir, moved)} already exists`);
  const html = readFileSync(document, "utf8");
  if (html.split(ENTRY_IMPORT).length !== 2) {
    throw new Error(`pack-pages: ${page}/index.html does not import ./app.js exactly once`);
  }
  if (html.includes('href="app.js"') || html.includes('href="./app.js"')) {
    throw new Error(`pack-pages: ${page}/index.html links app.js outside its entry import`);
  }
  writeFileSync(document, html.replace(ENTRY_IMPORT, `import "../__shared/page-${page}.js";`));
  renameSync(entry, moved);
  return moved;
}

/** Replaces `file` by its raw-deflated copy when that is smaller; returns [raw, stored] bytes. */
export function packFile(file) {
  const raw = readFileSync(file);
  const packed = deflateRawSync(raw, { level: 9 });
  if (packed.length >= raw.length) return [raw.length, raw.length];
  writeFileSync(file + PACKED_SUFFIX, packed);
  rmSync(file);
  return [raw.length, packed.length];
}

export function packPages({ outdir, metafile, keep, pages, cwd = process.cwd() }) {
  // What first paint can read: the kept pages' entries and their static imports.
  const graph = importGraph(metafile, cwd, { staticOnly: true });
  const shared = path.join(outdir, "__shared");
  const kept = reachable(
    graph,
    keep.map((page) => path.join(outdir, page, "app.js")),
  );
  for (const page of keep) {
    if (!kept.has(path.join(outdir, page, "app.js")) || !graph.has(path.join(outdir, page, "app.js"))) {
      throw new Error(`pack-pages: kept page ${page} has no entry in the metafile`);
    }
  }
  let moved = 0;
  for (const page of pages) {
    if (keep.includes(page)) continue;
    moveEntry(outdir, page);
    moved += 1;
  }
  let raw = 0;
  let stored = 0;
  let files = 0;
  for (const name of readdirSync(shared).sort()) {
    const file = path.join(shared, name);
    if (!name.endsWith(".js") || kept.has(file) || !statSync(file).isFile()) continue;
    const [before, after] = packFile(file);
    raw += before;
    stored += after;
    if (after < before) files += 1;
  }
  return { moved, files, raw, stored };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const keepAt = args.indexOf("--keep");
  if (keepAt < 0 || args.length < 4) throw new Error("usage: pack-pages.mjs OUTDIR METAFILE --keep PAGE,... PAGE...");
  const keep = args[keepAt + 1].split(",").filter(Boolean);
  const rest = args.filter((_, index) => index !== keepAt && index !== keepAt + 1);
  const [outdir, metafilePath, ...pages] = rest;
  const result = packPages({
    outdir: path.resolve(outdir),
    metafile: JSON.parse(readFileSync(metafilePath, "utf8")),
    keep,
    pages,
  });
  console.error(
    `pages packed: ${result.moved} entries moved to __shared, ${result.files} scripts deflated, ` +
      `${result.raw} -> ${result.stored} bytes`,
  );
}
