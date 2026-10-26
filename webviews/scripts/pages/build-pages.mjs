// Builds every React page (src/pages/<page>/main.tsx) in one esbuild run with code splitting, as
// Chrome's WebUI builds its pages against one shared module set (ui/webui/resources/tools/
// optimize_webui.gni, chrome://resources). Code two pages share lands once in a content-hashed
// chunk under _shared/; each page gets index.html (markup, its one <style>, modulepreload for
// every file its first frame runs), its entry app-<hash>.js and its strings. No inline script: the
// page runs only same-origin script files. Used by scripts/cmux-next/build-pages-web.sh.
//
//   bun scripts/pages/build-pages.mjs --out <dir> --pages "<page> ..." [--split-strings "<page> ..."]
//       [--shiki <dir>] [--report <file>]
//
// <dir> gets _shared/<chunk>.js and, per page, <page>/index.html, <page>/app-<hash>.js,
// <page>/_shared/ (the chunks that page reaches) and <page>/locales/ (--split-strings pages). An
// entry imports its chunks as ../_shared/<chunk>.js: on the daemon's /pages/<page>/ that is the one
// /pages/_shared/ copy, on the page's own cmux-page:// origin (which serves only its folder) the
// page's copy. --shiki resolves `shiki` to the agent pane's trimmed copy (pages that render the
// pane's Markdown). Every import, script and preload is checked to resolve on both (checkPageTree).
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appBundleOptions, reactCompilerPass, shikiAlias, sourcePlugins } from "../agent-pane/bundle.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const pagesRoot = path.resolve(here, "../../src/pages");
const SHARED = "_shared";

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
const ANY = new Set(["import-statement", "dynamic-import"]);

/** The page's index.html. Every href and src is relative to the page's folder. */
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

async function buildPages(options) {
  const work = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TMPDIR ?? "/tmp"), "cmux-pages-"));
  try {
    const compiler = reactCompilerPass();
    const result = await build({
      ...appBundleOptions,
      entryPoints: options.pages.map((page) => path.join(pagesRoot, page, "main.tsx")),
      outbase: pagesRoot,
      outdir: work,
      splitting: true,
      minify: true,
      metafile: true,
      entryNames: "[dir]/app-[hash]",
      chunkNames: `${SHARED}/[name]-[hash]`,
      alias: shikiAlias(options.shiki),
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
          outputs[file].entryPoint && path.resolve(outputs[file].entryPoint) === path.join(pagesRoot, page, "main.tsx"),
      );
      if (!entryFile) throw new Error(`esbuild wrote no entry for ${page}`);
      const dir = path.join(options.out, page);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(path.join(dir, SHARED), { recursive: true });
      fs.copyFileSync(path.join(work, entryFile), path.join(dir, path.basename(entryFile)));
      for (const chunk of closure(outputs, entryFile, ANY).slice(1))
        fs.copyFileSync(path.join(work, chunk), path.join(dir, chunk));
      const cssBundle = outputs[entryFile].cssBundle;
      const css = cssBundle ? fs.readFileSync(path.join(work, outputPath(cssBundle)), "utf8").trimEnd() : "";
      const loader = options.splitStrings.includes(page)
        ? execFileSync(
            process.execPath,
            [
              path.join(here, "split-strings.mjs"),
              path.join(pagesRoot, page, "generated/strings.json"),
              path.join(dir, "locales"),
              "--loader-file",
            ],
            { encoding: "utf8" },
          )
        : "";
      const firstLoad = closure(outputs, entryFile, STATIC);
      const preload = firstLoad.slice(1).map((chunk) => `../${chunk}`);
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

const IMPORT = /(?:\bfrom|\bimport)\s*\(?\s*"(\.{1,2}\/[^"]+\.js)"/g;
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

/** The two servers of a page: where its document is and which tree file a URL path names. */
const SERVERS = [
  { name: "the page's origin", document: () => "index.html", file: (page, url) => path.join(page, url) },
  { name: "the daemon's /pages/", document: (page) => `${page}/index.html`, file: (_page, url) => url },
];

/**
 * The problems in a built pages tree (`root`, the --out directory) for `pages`: an inline script, a
 * page with no module script, or a script, modulepreload or import that does not resolve to a file
 * on either server: the page's own origin (its folder is the root) and the daemon's /pages/<page>/
 * (the tree is the root). Empty when the tree is whole.
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
      const document = server.document(page);
      const scripts = [];
      const reach = (from, specifier) => {
        const url = resolveUrlPath(from, specifier);
        if (!exists(server.file(page, url)))
          problems.push(`${server.file(page, from)}: ${specifier} is not on ${server.name}`);
        return url;
      };
      for (const tag of tags) {
        if (!tag.loads || !tag.source) continue;
        const url = reach(document, tag.source);
        if (tag.module) scripts.push(url);
      }
      const seen = new Set();
      while (scripts.length) {
        const url = scripts.pop();
        if (seen.has(url) || !exists(server.file(page, url))) continue;
        seen.add(url);
        for (const [, specifier] of fs.readFileSync(path.join(root, server.file(page, url)), "utf8").matchAll(IMPORT))
          scripts.push(reach(url, specifier));
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
