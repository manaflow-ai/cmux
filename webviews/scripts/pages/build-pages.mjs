// Builds every React page (src/pages/<page>/main.tsx) in one esbuild run with code splitting, as
// Chrome's WebUI builds its pages against one shared module set (ui/webui/resources/tools/
// optimize_webui.gni, chrome://resources). Code two pages share lands once in a content-hashed
// chunk under _shared/; each page gets index.html (markup, its one <style>, modulepreload for
// every file its first frame runs), its entry app-<hash>.js and its strings. No inline script: the
// page runs only script files. Used by scripts/cmux-next/build-pages-web.sh.
//
//   bun scripts/pages/build-pages.mjs --out <dir> --pages "<page> ..." [--split-strings "<page> ..."]
//       [--shiki <dir>] [--report <file>]
//
// <dir> gets _shared/<chunk>.js and, per page, <page>/index.html, <page>/app-<hash>.js and
// <page>/locales/ (--split-strings pages). A page names every chunk by the shared origin
// (SHARED_ORIGIN, cmux-page://cmux.shared/<chunk>.js, which the app serves from _shared/), as
// Chrome's WebUI pages name chrome://resources/, so a chunk has one URL whichever page loads it;
// chunks name each other relatively. The daemon's /pages/ serves the same tree to a browser and
// answers the shared origin's URLs at /pages/_shared/ (cmux-tui page_files.rs). --shiki resolves
// `shiki` to the agent pane's trimmed copy (pages that render the pane's Markdown). Every import,
// script and preload is checked to resolve on both (checkPageTree).
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appBundleOptions, reactCompilerPass, shikiAlias, sourcePlugins } from "../agent-pane/bundle.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const pagesRoot = path.resolve(here, "../../src/pages");
const SHARED = "_shared";
/** The origin the pages import the shared chunks from (PageID.sharedOrigin in CmuxNextPages). */
export const SHARED_ORIGIN = "cmux-page://cmux.shared/";

function parseArgs(argv) {
  const options = { pages: [], splitStrings: [], shiki: "-", out: undefined, report: undefined };
  const list = (value) => (value ?? "").split(/\s+/).filter(Boolean);
  for (let index = 0; index < argv.length; index += 2) {
    const [flag, value] = [argv[index], argv[index + 1]];
    if (value === undefined) throw new Error(`${flag} needs a value`);
    if (flag === "--out") options.out = path.resolve(value);
    else if (flag === "--pages") options.pages = list(value);
    else if (flag === "--split-strings") options.splitStrings = list(value);
    else if (flag === "--shiki") options.shiki = value;
    else if (flag === "--report") options.report = value;
    else throw new Error(`unknown option ${flag}`);
  }
  if (!options.out || !options.pages.length) throw new Error("--out and --pages are required");
  return options;
}

/** Every output file `file` reaches through `kinds` of imports, `file` first. */
function closure(outputs, file, kinds) {
  const seen = [file];
  for (let index = 0; index < seen.length; index++)
    for (const item of outputs[seen[index]].imports)
      if (kinds.has(item.kind) && outputs[item.path] && !seen.includes(item.path)) seen.push(item.path);
  return seen;
}

const STATIC = new Set(["import-statement"]);

/** The URL of the shared chunk at `chunk` (`_shared/<name>.js`, a path under the build's output). */
function sharedUrl(chunk) {
  return SHARED_ORIGIN + path.posix.relative(SHARED, chunk.split(path.sep).join("/"));
}

/**
 * `code`, an entry esbuild wrote at <page>/app-<hash>.js, with each of its `imports` (metafile
 * paths under the output, `_shared/<name>.js`) named by the shared origin instead of `../`.
 */
export function nameChunksBySharedOrigin(code, imports) {
  let named = code;
  for (const item of imports)
    if (item.path.startsWith(`${SHARED}/`)) named = named.replaceAll(`"../${item.path}"`, `"${sharedUrl(item.path)}"`);
  return named;
}

/** The page's index.html. `entry` is relative to the page's folder; `preload` holds shared-origin URLs. */
export function pageHtml({ page, entry, preload, loader, css }) {
  const lines = [
    "<!doctype html>",
    `<html lang="en" data-cmux-page="${page}">`,
    "<head>",
    '<meta charset="utf-8" />',
    '<meta name="viewport" content="width=device-width, initial-scale=1" />',
    ...[entry, ...preload].map((href) => `<link rel="modulepreload" href="${href}" />`),
    ...(loader ? [loader] : []),
    "<style>",
    css,
    "</style>",
    "</head>",
    "<body>",
    '<main id="root"></main>',
    `<script type="module" src="${entry}"></script>`,
    "</body>",
    "</html>",
    "",
  ];
  return lines.join("\n").replace(/[ \t]+$/gm, "");
}

/**
 * Builds `options.pages`, the folders of `options.pagesRoot` (src/pages unless a test passes its
 * own), into `options.out`.
 */
export async function buildPages(options) {
  const root = options.pagesRoot ?? pagesRoot;
  const work = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TMPDIR ?? "/tmp"), "cmux-pages-"));
  try {
    const compiler = reactCompilerPass();
    const result = await build({
      ...appBundleOptions,
      entryPoints: options.pages.map((page) => path.join(root, page, "main.tsx")),
      outbase: root,
      outdir: work,
      splitting: true,
      minify: true,
      metafile: true,
      entryNames: "[dir]/app-[hash]",
      chunkNames: `${SHARED}/[name]-[hash]`,
      alias: shikiAlias(options.shiki ?? "-"),
      plugins: [compiler.plugin, ...sourcePlugins({ split: true })],
    });
    await compiler.finish(options.report);
    const outputPath = (file) => path.relative(work, path.resolve(file));
    const outputs = Object.fromEntries(
      Object.entries(result.metafile.outputs).map(([file, output]) => [outputPath(file), output]),
    );
    for (const output of Object.values(outputs)) for (const item of output.imports) item.path = outputPath(item.path);
    // Each page's <style> is its entry's stylesheet, which holds every sheet the page imports,
    // through dynamic imports too; any other stylesheet would never load.
    const pageCss = new Set(
      Object.values(outputs).flatMap((output) => (output.cssBundle ? [outputPath(output.cssBundle)] : [])),
    );
    const strayCss = Object.keys(outputs).filter((file) => file.endsWith(".css") && !pageCss.has(file));
    if (strayCss.length) throw new Error(`stylesheets no page loads: ${strayCss.join(", ")}`);

    fs.rmSync(path.join(options.out, SHARED), { recursive: true, force: true });
    fs.cpSync(path.join(work, SHARED), path.join(options.out, SHARED), { recursive: true });
    for (const page of options.pages) {
      const entryFile = Object.keys(outputs).find(
        (file) =>
          outputs[file].entryPoint && path.resolve(outputs[file].entryPoint) === path.join(root, page, "main.tsx"),
      );
      if (!entryFile) throw new Error(`esbuild wrote no entry for ${page}`);
      const dir = path.join(options.out, page);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true });
      const entryCode = fs.readFileSync(path.join(work, entryFile), "utf8");
      fs.writeFileSync(
        path.join(dir, path.basename(entryFile)),
        nameChunksBySharedOrigin(entryCode, outputs[entryFile].imports),
      );
      const cssBundle = outputs[entryFile].cssBundle;
      const css = cssBundle ? fs.readFileSync(path.join(work, outputPath(cssBundle)), "utf8").trimEnd() : "";
      const loader = (options.splitStrings ?? []).includes(page)
        ? execFileSync(
            process.execPath,
            [
              path.join(here, "split-strings.mjs"),
              path.join(root, page, "generated/strings.json"),
              path.join(dir, "locales"),
              "--loader-file",
            ],
            { encoding: "utf8" },
          )
        : "";
      const firstLoad = closure(outputs, entryFile, STATIC);
      const preload = firstLoad.slice(1).map(sharedUrl);
      fs.writeFileSync(
        path.join(dir, "index.html"),
        pageHtml({ page, entry: path.basename(entryFile), preload, loader, css }),
      );
      const bytes = firstLoad.reduce((sum, file) => sum + outputs[file].bytes, 0);
      console.log(`built ${page}: ${firstLoad.length} first-load scripts (${bytes} bytes)`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

const IMPORT = /(?:\bfrom|\bimport)\s*\(?\s*"((?:\.{1,2}\/|cmux-page:\/\/cmux\.shared\/)[^"]+\.js)"/g;
const TAG = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>|<link\b([^>]*)>/gi;

/** `relative` resolved against the URL path `from` (a file's), clamped at `/` as URLs are. */
function resolveUrlPath(from, relative) {
  const parts = from.split("/").slice(0, -1);
  for (const part of relative.split("/")) {
    if (part === "..") parts.pop();
    else if (part !== "." && part !== "") parts.push(part);
  }
  return parts.join("/");
}

/**
 * The two servers of a page. A location is `{ root, url }`: the tree folder its origin serves and
 * the URL path under it. In the app the page's origin serves its folder and the shared origin
 * serves _shared/; the daemon serves the tree at /pages/ and the shared origin's URLs at
 * /pages/_shared/.
 */
const SERVERS = [
  {
    name: "the app's cmux-page:// origins",
    document: (page) => ({ root: page, url: "index.html" }),
    shared: (url) => ({ root: SHARED, url }),
  },
  {
    name: "the daemon's /pages/",
    document: (page) => ({ root: "", url: `${page}/index.html` }),
    shared: (url) => ({ root: "", url: `${SHARED}/${url}` }),
  },
];

/** The location `specifier` names from `from` on `server`. */
function locate(server, from, specifier) {
  if (specifier.startsWith(SHARED_ORIGIN))
    return server.shared(resolveUrlPath("", specifier.slice(SHARED_ORIGIN.length)));
  if (/^[a-z][a-z0-9+.-]*:/i.test(specifier)) return undefined;
  return { root: from.root, url: resolveUrlPath(from.url, specifier) };
}

const treeFile = (location) => path.posix.join(location.root, location.url);

/**
 * The problems in a built pages tree (`root`, the --out directory) for `pages`: an inline script, a
 * page with no module script, or a script, modulepreload or import that does not resolve to a file
 * on either server (SERVERS): the app's cmux-page:// origins (the page's origin serves its folder,
 * cmux.shared serves _shared/) and the daemon's /pages/ (the tree). Empty when the tree is whole.
 */
export function checkPageTree(root, pages) {
  const problems = [];
  const exists = (file) => fs.existsSync(path.join(root, file)) && fs.statSync(path.join(root, file)).isFile();
  for (const page of pages) {
    const htmlFile = path.join(root, page, "index.html");
    if (!fs.existsSync(htmlFile)) {
      problems.push(`${page}: no index.html`);
      continue;
    }
    const tags = [...fs.readFileSync(htmlFile, "utf8").matchAll(TAG)].map((match) => {
      const script = match[1] !== undefined;
      const attributes = script ? match[1] : match[3];
      return {
        script,
        inline: script && match[2].trim() !== "",
        source: /\b(?:src|href)="([^"]+)"/.exec(attributes)?.[1],
        module: /type="module"|rel="modulepreload"/.test(attributes),
        loads: script || /rel="modulepreload"/.test(attributes),
      };
    });
    for (const tag of tags) {
      if (tag.script && !tag.source) problems.push(`${page}/index.html: inline script`);
      if (tag.inline) problems.push(`${page}/index.html: a script with inline code`);
    }
    if (!tags.some((tag) => tag.module && tag.source)) problems.push(`${page}/index.html: no module script`);
    for (const server of SERVERS) {
      const scripts = [];
      const reach = (from, specifier) => {
        const location = locate(server, from, specifier);
        if (!location || !exists(treeFile(location))) {
          problems.push(`${treeFile(from)}: ${specifier} is not on ${server.name}`);
          return undefined;
        }
        return location;
      };
      const document = server.document(page);
      for (const tag of tags) {
        if (!tag.loads || !tag.source) continue;
        const location = reach(document, tag.source);
        if (location && tag.module) scripts.push(location);
      }
      const seen = new Set();
      while (scripts.length) {
        const location = scripts.pop();
        const key = `${location.root}|${location.url}`;
        if (seen.has(key)) continue;
        seen.add(key);
        for (const [, specifier] of fs.readFileSync(path.join(root, treeFile(location)), "utf8").matchAll(IMPORT)) {
          const next = reach(location, specifier);
          if (next) scripts.push(next);
          // A chunk on the page's own origin would have a different URL on every page.
          if (next && next.root === page)
            problems.push(`${treeFile(location)}: ${specifier} is not on ${SHARED_ORIGIN}`);
        }
      }
    }
  }
  return problems;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const options = parseArgs(process.argv.slice(2));
  await buildPages(options);
  const problems = checkPageTree(options.out, options.pages);
  if (problems.length) {
    for (const problem of problems) console.error(`error: ${problem}`);
    process.exit(1);
  }
}
