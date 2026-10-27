#!/usr/bin/env node
// Reports what each cmux web page loads before its first frame, against the D8 bundle caps of the
// Chrome-parity plan (plans/cmux-next/chrome-parity/p13-webui.md, D8 and task 051). Agents run it
// after a web build; it is not a CI gate.
//
// Chrome serves the code every WebUI page needs from one origin, chrome://resources
// (ui/webui/resources/BUILD.gn, docs/webui/webui_build_configuration.md), so each page fetches
// the same URL and shares one cache entry. cmux does the same with cmux-page://cmux.shared/,
// written under Resources/pages/_shared/ (tasks 049, 050, 072). Per document the report prints:
//
//   own JS     first-load JavaScript not served from cmux.shared (minified, uncompressed), with
//              inline scripts and the largest locale table a <head> loader can add
//   shared JS  first-load JavaScript served from cmux.shared
//   total JS   own + shared
//   requests   first-load requests: script and stylesheet files, modulepreloads, the static
//              imports of module scripts, and the locale script a loader can add
//   lazy       chunks reachable only through dynamic import()
//   inline JS  bytes of inline script (the split build ships none)
//   React URL  the URL of the script that holds the react package (first load, else lazy)
//
// Caps (KB = 1000 bytes): own <= 250 KB, shared <= 400 KB, total <= 600 KB and requests <= 4 for
// every page and the agent pane; one React URL across the pages, the agent pane, diff, markdown,
// editor and agent-activity; the Settings first load holds the navigation and at most one section.
//
// A Settings section is a category of the settings schema (schemas/settings/settings-schema.json,
// page.categories) that draws a card; a category of schema rows only has no code of its own.
// webviews/src/pages/settings/lazySections.ts (task 081) names each section's module as
// `<category id>: () => import("<module>")`. esbuild writes a dynamic import target to its own chunk
// named after the module, <module basename>-<hash>.js (build-pages.mjs, chunkNames), so a section is
// lazy when that chunk is reachable only through import(). A section with no entry, or whose chunk is
// in the first load, is in the first load; more than one of those is a finding. Other lazy chunks
// (the glass lens every page imports) say nothing about the sections. A lazy section paints with
// one file (task 081): its chunk's static imports outside the first load load one after another,
// so a section that loads more than one file after the first load is a finding too.
//
//   node scripts/cmux-next/page-bundle-report.mjs                    # the in-tree build output
//   node scripts/cmux-next/page-bundle-report.mjs --root DIR         # a build-web-bundles.sh --out-root tree
//   node scripts/cmux-next/page-bundle-report.mjs --pages /tmp/pages # build-pages-web.sh --out /tmp/pages
//   ... --agent-pane DIR --agent-activity DIR --webviews-app DIR     # one tree from elsewhere
//   ... --json                                                       # the same report as JSON
//   ... --baseline BASE.json   # also each document's total JS and requests against a --json report of the base
//
// Exits 0 when every cap holds, 1 when one fails or a document is missing, 2 on a usage error.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// The output paths build-web-bundles.sh writes, relative to the repository (or --out-root) root.
const TREES = {
  pages: "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
  agentPane: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
  agentActivity: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
  webviewsApp: "Resources/markdown-viewer/webviews-app",
};

export const KB = 1000;
export const CAPS = { ownBytes: 250 * KB, sharedBytes: 400 * KB, totalBytes: 600 * KB, requests: 4 };
export const SHARED_HOST = "cmux.shared";

// The react package assigns its internals export; react-dom and react-dom/server only read it.
const REACT_MARKER =
  /\.__(?:CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE|SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED)\s*=(?!=)/;
// The <head> locale loader (webviews/scripts/pages/split-strings.mjs) writes one more script.
const LOCALE_WRITE = /document\.write\(\s*'<script src="([^"']+)\/'\s*\+/;
// Static `import ... from "x"`, `import "x"`, `export ... from "x"` in esbuild or Vite output.
const STATIC_IMPORT =
  /(?:^|[;}\s])(?:import|export)\s*(?:(?:\*\s*as\s+[\w$]+|\*|\{[^}]*\}|[\w$]+(?:\s*,\s*(?:\*\s*as\s+[\w$]+|\{[^}]*\}))?)\s*from\s*)?(["'])([^"'\n]+)\1/g;
const DYNAMIC_IMPORT = /\bimport\s*\(\s*(["'`])([^"'`\n]+)\1\s*\)/g;

/** The page directories build-pages-web.sh builds (its PAGES list). */
export function pageNames(repo = REPO) {
  const script = readFileSync(join(repo, "scripts/cmux-next/build-pages-web.sh"), "utf8");
  const match = script.match(/^PAGES="([^"]*)"/m);
  if (!match) throw new Error("scripts/cmux-next/build-pages-web.sh has no PAGES=\"...\" line");
  return match[1].split(/\s+/).filter(Boolean);
}

/** Every document D8 names, with the URL it is served at and the file it is built to. */
export function documents({ pages, agentPane, agentActivity, webviewsApp }, names) {
  const doc = (name, dir, entry, host, capped) => ({
    name,
    dir,
    file: join(dir, entry),
    url: `cmux-page://${host}/${entry}`,
    capped,
  });
  return [
    ...names.map((name) => doc(name, join(pages, name), "index.html", `cmux.${name}`, true)),
    doc("agent pane", agentPane, "index.html", "cmux.agent", true),
    doc("diff", webviewsApp, "diff-page.html", "cmux.diff", false),
    doc("markdown", webviewsApp, "markdown-page.html", "cmux.markdown", false),
    doc("editor", webviewsApp, "editor-page.html", "cmux.editor", false),
    doc("agent-activity", agentActivity, "index.html", "cmux.agent-activity", false),
  ];
}

function attributes(text) {
  const attrs = {};
  for (const m of text.matchAll(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g)) {
    attrs[m[1].toLowerCase()] = m[2] ?? m[3] ?? m[4] ?? "";
  }
  return attrs;
}

/** The first-load references of an HTML document: scripts, inline scripts and links. */
export function parseHtml(html) {
  const body = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<style\b[^>]*>[\s\S]*?<\/style\s*>/gi, "");
  const scripts = [];
  for (const m of body.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
    const attrs = attributes(m[1]);
    scripts.push({ src: attrs.src, module: attrs.type === "module", inline: attrs.src === undefined ? m[2] : "" });
  }
  const links = [];
  for (const m of body.replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, "").matchAll(/<link\b([^>]*)>/gi)) {
    const attrs = attributes(m[1]);
    const rel = (attrs.rel ?? "").toLowerCase().split(/\s+/);
    if (!attrs.href) continue;
    if (rel.includes("modulepreload")) links.push({ href: attrs.href, kind: "module" });
    else if (rel.includes("preload") && attrs.as === "script") links.push({ href: attrs.href, kind: "script" });
    else if (rel.includes("stylesheet")) links.push({ href: attrs.href, kind: "style" });
  }
  return { scripts, links };
}

// A built chunk: a relative, root or cmux-page URL of a .js or .mjs file.
const isLocalSpecifier = (spec) => /^(?:\.{1,2}\/|\/|cmux-page:)[^?#]*\.m?js(?:[?#]|$)/.test(spec);

/** The local module specifiers a module imports statically and dynamically. */
export function moduleImports(code) {
  const pick = (re) => [...code.matchAll(re)].map((m) => m[2]).filter(isLocalSpecifier);
  return { static: [...new Set(pick(STATIC_IMPORT))], dynamic: [...new Set(pick(DYNAMIC_IMPORT))] };
}

// The file types cmux.shared serves (PageSharedChunks.servedExtensions); any other is refused.
const SHARED_EXTENSIONS = new Set([".js", ".css"]);

/**
 * Maps a served URL to its built file: the document's own host, or cmux.shared, which serves only
 * the .js and .css files under pages/_shared (PageSharedChunks.file(for:root:)). null when no
 * handler serves the URL.
 */
function fileFor(url, doc, sharedDir) {
  const u = new URL(url);
  if (u.protocol !== "cmux-page:") return null;
  const path = decodeURIComponent(u.pathname);
  if (u.host === new URL(doc.url).host) return join(doc.dir, path);
  if (u.host !== SHARED_HOST || !SHARED_EXTENSIONS.has(extname(path))) return null;
  return join(sharedDir, path);
}

const isShared = (url) => new URL(url).host === SHARED_HOST;
// Inline script keys ("inline #1 in ...") are never shared.
const sharedKey = (key) => key.startsWith("cmux-page:") && isShared(key);
const isFile = (file) => file !== null && existsSync(file) && statSync(file).isFile();

/** Measures one document's first load. */
export function measure(doc, sharedDir) {
  const row = {
    name: doc.name,
    url: doc.url,
    capped: doc.capped,
    missing: !isFile(doc.file),
    ownBytes: 0,
    sharedBytes: 0,
    inlineBytes: 0,
    requests: 0,
    lazyChunks: 0,
    firstLoad: [],
    lazy: [],
    // Each dynamic import() target: the files its import loads outside the first load, itself first.
    lazyLoads: {},
    react: [],
    reactLazy: false,
    unresolved: [],
  };
  if (row.missing) return row;
  const { scripts, links } = parseHtml(readFileSync(doc.file, "utf8"));
  const requested = new Map(); // url -> { file, module, js }
  const lazyRoots = [];
  const sources = new Map(); // url (or inline key) -> code, for the React search
  const request = (spec, base, kind) => {
    const url = new URL(spec, base).href;
    if (requested.has(url)) return;
    const file = fileFor(url, doc, sharedDir);
    if (!isFile(file)) {
      row.unresolved.push(url);
      return;
    }
    requested.set(url, { file, kind });
    if (kind === "style") return;
    const code = readFileSync(file, "utf8");
    sources.set(url, code);
    if (kind !== "module") return;
    const imports = moduleImports(code);
    for (const next of imports.static) request(next, url, "module");
    lazyRoots.push(...imports.dynamic.map((next) => new URL(next, url).href));
  };
  for (const [index, script] of scripts.entries()) {
    if (script.src !== undefined) {
      request(script.src, doc.url, script.module ? "module" : "script");
      continue;
    }
    row.inlineBytes += Buffer.byteLength(script.inline);
    sources.set(`inline #${index + 1} in ${doc.url}`, script.inline);
    if (!script.module) continue;
    const imports = moduleImports(script.inline);
    for (const next of imports.static) request(next, doc.url, "module");
    lazyRoots.push(...imports.dynamic.map((next) => new URL(next, doc.url).href));
  }
  for (const link of links) request(link.href, doc.url, link.kind);
  const localeDir = [...sources.values()].map((code) => code.match(LOCALE_WRITE)?.[1]).find(Boolean) ?? null;

  for (const [url, { file, kind }] of requested) {
    if (kind === "style") continue;
    const bytes = statSync(file).size;
    if (isShared(url)) row.sharedBytes += bytes;
    else row.ownBytes += bytes;
  }
  row.ownBytes += row.inlineBytes;
  row.requests = requested.size;
  row.firstLoad = [...requested.keys()];
  const locale = localeDir === null ? null : largestLocale(join(doc.dir, localeDir), requested);
  if (locale !== null) {
    row.ownBytes += locale;
    row.requests += 1;
  }
  const lazy = lazySources(lazyRoots, requested, doc, sharedDir, row);
  row.lazyChunks = lazy.size;
  row.lazy = [...lazy.keys()];
  row.lazyLoads = Object.fromEntries(
    [...new Set(lazyRoots)].filter((url) => lazy.has(url)).map((url) => [url, staticLoad(url, requested, lazy)]),
  );
  // React in the first load, else in a lazy chunk (the diff page mounts React after boot); a
  // shared copy first, as it is the URL every document should name.
  const holders = (map) => [...map].filter(([, code]) => REACT_MARKER.test(code)).map(([key]) => key);
  const first = holders(sources);
  row.react = (first.length > 0 ? first : holders(lazy)).sort((a, b) => Number(sharedKey(b)) - Number(sharedKey(a)));
  row.reactLazy = first.length === 0 && row.react.length > 0;
  return row;
}

/** The largest locale table a <head> loader can add besides the ones the page names itself. */
function largestLocale(dir, requested) {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return null;
  const named = new Set([...requested.values()].map(({ file }) => resolve(file)));
  const sizes = readdirSync(dir)
    .filter((name) => name.endsWith(".js") && name !== "loader.js")
    .map((name) => join(dir, name))
    .filter((file) => !named.has(resolve(file)))
    .map((file) => statSync(file).size);
  return sizes.length === 0 ? null : Math.max(...sizes);
}

/** The files an import() of `url` loads outside the first load (`requested`): it and its static imports. */
function staticLoad(url, requested, lazy) {
  const files = [url];
  for (let index = 0; index < files.length; index++)
    for (const next of moduleImports(lazy.get(files[index])).static) {
      const nextUrl = new URL(next, files[index]).href;
      if (!requested.has(nextUrl) && lazy.has(nextUrl) && !files.includes(nextUrl)) files.push(nextUrl);
    }
  return files;
}

/** Chunks reachable through dynamic import() and their own imports, outside the first load. */
function lazySources(roots, requested, doc, sharedDir, row) {
  const seen = new Map(); // url -> code
  const queue = [...roots];
  while (queue.length > 0) {
    const url = queue.shift();
    if (requested.has(url) || seen.has(url)) continue;
    const file = fileFor(url, doc, sharedDir);
    if (!isFile(file)) {
      row.unresolved.push(url);
      continue;
    }
    const code = readFileSync(file, "utf8");
    seen.set(url, code);
    const imports = moduleImports(code);
    for (const next of [...imports.static, ...imports.dynamic]) queue.push(new URL(next, url).href);
  }
  return seen;
}

const SETTINGS_SCHEMA = "schemas/settings/settings-schema.json";
const LAZY_SECTIONS = "webviews/src/pages/settings/lazySections.ts";
// `<id>: () => import("<module>")`, the id bare or quoted.
const LAZY_ENTRY =
  /(?:"([\w-]+)"|'([\w-]+)'|([\w$]+))\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*import\(\s*(["'`])([^"'`\n]+)\4\s*\)/g;

/** The chunk name esbuild gives a dynamic import target: the module's basename, no extension. */
const chunkName = (specifier) => basename(specifier).replace(/\.[cm]?[jt]sx?$/, "");
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * The Settings sections and the chunk each is built to: every schema category with a card
 * (`categories` is schema.page.categories) and every entry of lazySections.ts (`lazySource`, null
 * when the file is missing). `chunk` is null for a section lazySections.ts does not name.
 */
export function sectionChunks(categories, lazySource) {
  const problems = [];
  const entries = new Map();
  if (lazySource === null) problems.push(`${LAZY_SECTIONS} is missing, so the first load holds every section`);
  for (const m of (lazySource ?? "").matchAll(LAZY_ENTRY)) entries.set(m[1] ?? m[2] ?? m[3], chunkName(m[5]));
  const byChunk = new Map();
  for (const [id, chunk] of entries) byChunk.set(chunk, [...(byChunk.get(chunk) ?? []), id]);
  for (const [chunk, ids] of byChunk) {
    if (ids.length > 1) problems.push(`sections ${ids.join(", ")} share the chunk name ${chunk}, so their chunks cannot be told apart`);
  }
  const carded = categories
    .filter((category) => (category.lead ?? []).length + (category.trail ?? []).length > 0)
    .map((category) => category.id);
  const ids = [...new Set([...carded, ...entries.keys()])];
  return { sections: ids.map((id) => ({ id, chunk: entries.get(id) ?? null })), problems };
}

/** The Settings sections of the repository's sources (sectionChunks). */
export function settingsSections(repo = REPO) {
  const schema = JSON.parse(readFileSync(join(repo, SETTINGS_SCHEMA), "utf8"));
  const lazyFile = join(repo, LAZY_SECTIONS);
  return sectionChunks(schema.page.categories, existsSync(lazyFile) ? readFileSync(lazyFile, "utf8") : null);
}

/** The URL in `urls` of the chunk esbuild wrote for the module `chunk` (<chunk>-<hash>.js). */
function chunkUrl(urls, chunk) {
  const pattern = new RegExp(`^${escapeRegExp(chunk)}-[A-Z0-9]+\\.js$`);
  return urls.find((url) => pattern.test(basename(new URL(url).pathname)));
}

/**
 * The lazy Settings sections whose import loads more than one file after the first load, each as
 * "<id> loads <n> files (<names>)". The files a module imports load one after another (an import()
 * fetches its static imports only once it has the file), so a section paints with one file only.
 */
function sectionWaterfalls(row, sections) {
  return sections.flatMap(({ id, chunk }) => {
    const url = chunk === null ? undefined : chunkUrl(Object.keys(row.lazyLoads), chunk);
    const files = url ? row.lazyLoads[url] : [];
    if (files.length <= 1) return [];
    return [`${id} loads ${files.length} files (${files.map((file) => basename(new URL(file).pathname)).join(", ")})`];
  });
}

/** The Settings sections a measured row's first load holds, each as "<id> (<why>)". */
function firstLoadSections(row, sections) {
  return sections.flatMap(({ id, chunk }) => {
    if (chunk === null) return [`${id} (not in lazySections.ts)`];
    if (chunkUrl(row.lazy, chunk)) return [];
    const first = chunkUrl(row.firstLoad, chunk);
    return [first ? `${id} (${first} loads first)` : `${id} (no lazy ${chunk}-<hash>.js chunk)`];
  });
}

/**
 * The D8 findings over the measured rows; an empty list means every cap holds. `sections` is
 * settingsSections()'s result, for the Settings check.
 */
export function findings(rows, sections = settingsSections()) {
  const out = [];
  const kb = (bytes) => `${(bytes / KB).toFixed(1)} KB`;
  for (const row of rows) {
    if (row.missing) {
      out.push(`${row.name}: not built (${row.url})`);
      continue;
    }
    for (const url of row.unresolved) out.push(`${row.name}: ${url} does not resolve to a built file`);
    if (row.react.length === 0) out.push(`${row.name}: no script it loads holds React`);
    if (row.react.length > 1) out.push(`${row.name}: ${row.react.length} copies of React (${row.react.join(", ")})`);
    if (!row.capped) continue;
    if (row.ownBytes > CAPS.ownBytes) out.push(`${row.name}: own JS ${kb(row.ownBytes)} > ${kb(CAPS.ownBytes)}`);
    if (row.sharedBytes > CAPS.sharedBytes) out.push(`${row.name}: shared JS ${kb(row.sharedBytes)} > ${kb(CAPS.sharedBytes)}`);
    const total = row.ownBytes + row.sharedBytes;
    if (total > CAPS.totalBytes) out.push(`${row.name}: total JS ${kb(total)} > ${kb(CAPS.totalBytes)}`);
    if (row.requests > CAPS.requests) out.push(`${row.name}: ${row.requests} requests > ${CAPS.requests}`);
  }
  const built = rows.filter((row) => !row.missing && row.react.length > 0);
  const urls = new Set(built.map((row) => row.react[0]));
  if (urls.size > 1) out.push(`React URL: ${urls.size} different URLs across ${built.length} documents (D8 wants one)`);
  const settings = rows.find((row) => row.name === "settings");
  if (settings && !settings.missing) {
    for (const problem of sections.problems) out.push(`settings: ${problem}`);
    const first = firstLoadSections(settings, sections.sections);
    if (first.length > 1) {
      out.push(`settings: the first load holds ${first.length} sections (D8 wants the navigation and one): ${first.join(", ")}`);
    }
    for (const waterfall of sectionWaterfalls(settings, sections.sections))
      out.push(`settings: section ${waterfall} after the first load (task 081 wants one)`);
  }
  return out;
}

function table(rows) {
  const kb = (bytes) => (bytes / KB).toFixed(1);
  const header = ["document", "own JS", "shared JS", "total JS", "requests", "lazy", "inline JS", "React URL"];
  const lines = rows.map((row) =>
    row.missing
      ? [row.name, "-", "-", "-", "-", "-", "-", "not built"]
      : [
          row.name,
          kb(row.ownBytes),
          kb(row.sharedBytes),
          kb(row.ownBytes + row.sharedBytes),
          String(row.requests),
          String(row.lazyChunks),
          kb(row.inlineBytes),
          row.react.length === 0 ? "none" : `${row.react.join(", ")}${row.reactLazy ? " (lazy)" : ""}`,
        ],
  );
  const widths = header.map((_, i) => Math.max(header[i].length, ...lines.map((line) => line[i].length)));
  const format = (cells) =>
    cells
      .map((cell, i) => (i === 0 || i === cells.length - 1 ? cell.padEnd(widths[i]) : cell.padStart(widths[i])))
      .join("  ")
      .trimEnd();
  return [format(header), ...lines.map(format)].join("\n");
}

/**
 * Each document measured in both `baseline` (a --json report's documents) and `rows`: its total
 * first-load JS and request count there and here, and whether either grew.
 */
export function compareWithBaseline(baseline, rows) {
  const before = new Map(baseline.filter((row) => !row.missing).map((row) => [row.name, row]));
  return rows
    .filter((row) => !row.missing && before.has(row.name))
    .map((row) => {
      const base = before.get(row.name);
      const baseBytes = base.ownBytes + base.sharedBytes;
      const bytes = row.ownBytes + row.sharedBytes;
      return {
        name: row.name,
        baseBytes,
        bytes,
        baseRequests: base.requests,
        requests: row.requests,
        grew: bytes > baseBytes || row.requests > base.requests,
      };
    });
}

function comparisonTable(comparison) {
  const kb = (bytes) => (bytes / KB).toFixed(1);
  const lines = comparison.map((row) => [
    row.name,
    `${kb(row.baseBytes)} -> ${kb(row.bytes)} KB (${row.bytes - row.baseBytes >= 0 ? "+" : ""}${row.bytes - row.baseBytes} B)`,
    `${row.baseRequests} -> ${row.requests} requests`,
    row.grew ? "GREW" : "",
  ]);
  const widths = [0, 1, 2].map((i) => Math.max(...lines.map((line) => line[i].length)));
  return lines.map((line) => line.map((cell, i) => (i < 3 ? cell.padEnd(widths[i]) : cell)).join("  ").trimEnd()).join("\n");
}

/** Measures every document of the given trees; `sections` as findings() takes it. */
export function report(trees, names, sections = settingsSections()) {
  const sharedDir = join(trees.pages, "_shared");
  const rows = documents(trees, names).map((doc) => measure(doc, sharedDir));
  const found = findings(rows, sections);
  return { caps: { ...CAPS, kb: KB }, documents: rows, findings: found, pass: found.length === 0 };
}

function parseArgs(argv) {
  const options = { root: REPO, json: false, overrides: {}, baseline: undefined };
  const flags = { "--pages": "pages", "--agent-pane": "agentPane", "--agent-activity": "agentActivity", "--webviews-app": "webviewsApp" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") options.json = true;
    else if (arg === "--baseline") {
      const value = argv[i + 1];
      if (!value) throw new UsageError("--baseline needs a --json report");
      options.baseline = resolve(value);
      i += 1;
    }
    else if (arg === "--root" || arg in flags) {
      const value = argv[i + 1];
      if (!value) throw new UsageError(`${arg} needs a directory`);
      if (arg === "--root") options.root = resolve(value);
      else options.overrides[flags[arg]] = resolve(value);
      i += 1;
    } else throw new UsageError(`unknown argument ${arg}`);
  }
  return options;
}

class UsageError extends Error {}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    console.error(`error: ${error.message}`);
    console.error(
      "usage: page-bundle-report.mjs [--root DIR] [--pages DIR] [--agent-pane DIR] [--agent-activity DIR] [--webviews-app DIR] [--json] [--baseline BASE.json]",
    );
    return 2;
  }
  const trees = Object.fromEntries(Object.entries(TREES).map(([key, path]) => [key, options.overrides[key] ?? join(options.root, path)]));
  const result = report(trees, pageNames());
  if (options.baseline) {
    result.baseline = compareWithBaseline(JSON.parse(readFileSync(options.baseline, "utf8")).documents, result.documents);
  }
  if (options.json) {
    console.log(JSON.stringify(result, null, 2));
    return result.pass ? 0 : 1;
  }
  console.log("D8 page bundles: first load, minified and uncompressed, KB = 1000 bytes");
  console.log(table(result.documents));
  console.log(
    `caps: own <= ${CAPS.ownBytes / KB} KB, shared <= ${CAPS.sharedBytes / KB} KB, total <= ${CAPS.totalBytes / KB} KB, ` +
      `requests <= ${CAPS.requests} (every page and the agent pane); one React URL; Settings first load: navigation and one section`,
  );
  for (const finding of result.findings) console.log(`FAIL ${finding}`);
  if (result.baseline) {
    const grew = result.baseline.filter((row) => row.grew).map((row) => row.name);
    console.log(`against ${options.baseline}: total first-load JS and requests`);
    console.log(comparisonTable(result.baseline));
    console.log(grew.length ? `baseline: ${grew.join(", ")} grew` : "baseline: no document grew");
  }
  console.log(result.pass ? "D8: pass" : `D8: FAIL (${result.findings.length} findings)`);
  return result.pass ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
