// Builds every React page (src/pages/<page>/main.tsx) in one esbuild run with code splitting, as
// Chrome's WebUI builds its pages against one shared module set (ui/webui/resources/tools/
// optimize_webui.gni, chrome://resources). Code two pages share lands once in a content-hashed
// chunk under _shared/; each page gets index.html (markup, its one <style>, modulepreload for
// every file its first frame runs), its entry app-<hash>.js and its strings. No inline script: the
// page runs only script files. Used by scripts/cmux-next/build-pages-web.sh.
//
//   bun scripts/pages/build-pages.mjs --out <dir> --pages "<page> ..." [--split-strings "<page> ..."]
//       [--shiki <dir>] [--report <file>] [--agent-pane <scripts dir>]
//   bun scripts/pages/build-pages.mjs --out <dir> [--pages "<page> ..."] --agent-pane <pane dir> --check-only
//
// React is the one shared React of every web tree the app ships (scripts/shared/shared-react.mjs,
// _shared/react-<hash>.js): external to every bundle, as chrome://resources is to every WebUI page,
// so every page, the agent pane, the webviews app and Agent Activity load it from one URL. This build
// writes that file into <dir>/_shared/ with the chunks, so checkPageTree checks it like any chunk.
//
// --agent-pane also builds the agent pane (src/agent-session/acpmux/main.tsx), as Chrome builds its
// New Tab page against chrome://resources like every other WebUI page, in a run of its own: it
// shares React with the pages and nothing else, so it never changes what a page loads.
// <scripts dir> gets the pane's entry app-<hash>.js, its chunks/ and preload.html, the
// modulepreload links of its first load; scripts/cmux-next/build-agent-pane-web.sh writes the
// pane's index.html around them. --check-only builds nothing: it checks the tree at <dir> and the
// pane page in <pane dir> (its index.html).
//
// <dir> gets _shared/<chunk>.js and, per page, <page>/index.html, <page>/app-<hash>.js and
// <page>/locales/ (--split-strings pages). A page names every chunk by the shared origin
// (SHARED_ORIGIN, cmux-page://cmux.shared/<chunk>.js, which the app serves from _shared/), as
// Chrome's WebUI pages name chrome://resources/, so a chunk has one URL whichever page loads it;
// chunks name each other relatively and React by its URL. The
// daemon's /pages/ serves the same tree to a browser and answers the shared origin's URLs at
// /pages/_shared/ (cmux-tui page_files.rs). --shiki resolves `shiki` to the agent pane's trimmed
// copy (pages that render the pane's Markdown). Every import, script and preload is checked to
// resolve on both (checkPageTree).
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appBundleOptions, reactCompilerPass, shikiAlias, sourcePlugins } from "../agent-pane/bundle.mjs";
import { buildSharedReact, sharedReactEsbuildPlugin } from "../shared/shared-react.mjs";
import { joinSectionChunks } from "./section-chunks.mjs";
import { SHARED_ORIGIN } from "./shared-origin.mjs";

export { SHARED_ORIGIN };

const here = path.dirname(fileURLToPath(import.meta.url));
const pagesRoot = path.resolve(here, "../../src/pages");
const SHARED = "_shared";
/** The agent pane's entry (PageDescriptor.agent, `cmux-page://cmux.agent/`). */
export const AGENT_PANE_ENTRY = path.resolve(here, "../../src/agent-session/acpmux/main.tsx");
/** The pane's name in checkPageTree's findings; its folder is not in the pages tree. */
export const AGENT_PANE = "agent-pane";

function parseArgs(argv) {
  const options = { pages: [], splitStrings: [], shiki: "-", out: undefined, report: undefined, checkOnly: false };
  const list = (value) => (value ?? "").split(/\s+/).filter(Boolean);
  for (let index = 0; index < argv.length; index += 2) {
    const [flag, value] = [argv[index], argv[index + 1]];
    if (flag === "--check-only") {
      options.checkOnly = true;
      index -= 1;
      continue;
    }
    if (value === undefined) throw new Error(`${flag} needs a value`);
    if (flag === "--out") options.out = path.resolve(value);
    else if (flag === "--pages") options.pages = list(value);
    else if (flag === "--split-strings") options.splitStrings = list(value);
    else if (flag === "--shiki") options.shiki = value;
    else if (flag === "--report") options.report = value;
    else if (flag === "--agent-pane") options.agentPane = { entry: AGENT_PANE_ENTRY, out: path.resolve(value) };
    else throw new Error(`unknown option ${flag}`);
  }
  if (!options.out) throw new Error("--out is required");
  if (options.checkOnly ? !options.agentPane && !options.pages.length : !options.pages.length)
    throw new Error(options.checkOnly ? "--check-only needs --pages or --agent-pane" : "--pages is required");
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

/** The modulepreload links of a first load: the entry (relative to the document), then `preload`. */
export function modulepreloadLinks(entry, preload) {
  return [entry, ...preload].map((href) => `<link rel="modulepreload" href="${href}" />`);
}

/** The page's index.html. `entry` is relative to the page's folder; `preload` holds shared-origin URLs. */
export function pageHtml({ page, entry, preload, loader, css }) {
  const lines = [
    "<!doctype html>",
    `<html lang="en" data-cmux-page="${page}">`,
    "<head>",
    '<meta charset="utf-8" />',
    '<meta name="viewport" content="width=device-width, initial-scale=1" />',
    ...modulepreloadLinks(entry, preload),
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
 * One esbuild run of `entryPoints` into `outdir` with the shared React external (`library`, its
 * plugin): the metafile's outputs keyed by their path under `outdir`, each import of an output named
 * the same way (an import of the shared React keeps its URL). Fails on a stylesheet no document loads.
 */
async function bundle({ entryPoints, outdir, outbase, entryNames, chunkNames, library, compiler, shiki }) {
  const result = await build({
    ...appBundleOptions,
    entryPoints,
    ...(outbase ? { outbase } : {}),
    outdir,
    splitting: true,
    minify: true,
    metafile: true,
    entryNames,
    chunkNames,
    alias: shikiAlias(shiki ?? "-"),
    plugins: [library, compiler.plugin, ...sourcePlugins({ split: true })],
  });
  const outputPath = (file) => path.relative(outdir, path.resolve(file));
  const outputs = Object.fromEntries(
    Object.entries(result.metafile.outputs).map(([file, output]) => [outputPath(file), output]),
  );
  for (const output of Object.values(outputs))
    for (const item of output.imports) if (!item.external) item.path = outputPath(item.path);
  // Each document's <style> is its entry's stylesheet, which holds every sheet it imports, through
  // dynamic imports too; any other stylesheet would never load.
  const css = new Set(
    Object.values(outputs).flatMap((output) => (output.cssBundle ? [outputPath(output.cssBundle)] : [])),
  );
  const strayCss = Object.keys(outputs).filter((file) => file.endsWith(".css") && !css.has(file));
  if (strayCss.length) throw new Error(`stylesheets no page loads: ${strayCss.join(", ")}`);
  return { outputs, outputPath };
}

/** The output esbuild wrote for the entry point `source`. */
function entryOutput(outputs, source, name) {
  const entryFile = Object.keys(outputs).find(
    (file) => outputs[file].entryPoint && path.resolve(outputs[file].entryPoint) === path.resolve(source),
  );
  if (!entryFile) throw new Error(`esbuild wrote no entry for ${name}`);
  return entryFile;
}

/** The specifiers the outputs `files` import statically that no run wrote (the shared React's URL). */
function externalImports(outputs, files) {
  const specifiers = files.flatMap((file) =>
    outputs[file].imports.filter((item) => item.external && STATIC.has(item.kind)).map((item) => item.path),
  );
  return [...new Set(specifiers)];
}

/** Logs what a document's first load runs from its own run; page-bundle-report counts the shared React too. */
function logFirstLoad(name, outputs, firstLoad, library) {
  const bytes = firstLoad.reduce((sum, file) => sum + outputs[file].bytes, 0);
  console.log(
    `built ${name}: ${firstLoad.length} first-load scripts (${bytes} bytes) and ${library.length} library file`,
  );
}

/**
 * Builds `options.pages`, the folders of `options.pagesRoot` (src/pages unless a test passes its
 * own), into `options.out`, and with `options.agentPane` (`{ entry, out }`) the agent pane into
 * `agentPane.out` (app-<hash>.js, chunks/ and preload.html). The shared React (shared-react.mjs) is
 * external to both runs and written into _shared: the pages' run splits what the pages share into
 * _shared, the pane's run keeps its code in its own folder.
 */
export async function buildPages(options) {
  const root = options.pagesRoot ?? pagesRoot;
  const agentPane = options.agentPane;
  const work = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TMPDIR ?? "/tmp"), "cmux-pages-"));
  const pagesWork = path.join(work, "pages");
  const paneWork = path.join(work, "agent-pane");
  try {
    const compiler = reactCompilerPass();
    const shared = await buildSharedReact();
    const runs = { compiler, shiki: options.shiki };
    const [pages, pane] = await Promise.all([
      options.pages.length > 0
        ? bundle({
            ...runs,
            entryPoints: options.pages.map((page) => path.join(root, page, "main.tsx")),
            outbase: root,
            outdir: pagesWork,
            entryNames: "[dir]/app-[hash]",
            chunkNames: `${SHARED}/[name]-[hash]`,
            library: sharedReactEsbuildPlugin(shared.url),
          })
        : undefined,
      agentPane
        ? bundle({
            ...runs,
            entryPoints: [agentPane.entry],
            outdir: paneWork,
            entryNames: "app-[hash]",
            chunkNames: "chunks/[name]-[hash]",
            library: sharedReactEsbuildPlugin(shared.url),
          })
        : undefined,
    ]);
    await compiler.finish(options.report);
    // A page's lazy sections (src/pages/<page>/sections/) load one file each and leave every other
    // page's chunks as they were with the sections built in (section-chunks.mjs).
    if (pages) {
      const pageEntries = new Map(
        options.pages.map((page) => [page, entryOutput(pages.outputs, path.join(root, page, "main.tsx"), page)]),
      );
      pages.outputs = await joinSectionChunks({
        outdir: pagesWork,
        outputs: pages.outputs,
        pageEntries,
        pagesRoot: root,
        target: appBundleOptions.target,
      });
    }

    fs.rmSync(path.join(options.out, SHARED), { recursive: true, force: true });
    fs.mkdirSync(path.join(options.out, SHARED), { recursive: true });
    if (fs.existsSync(path.join(pagesWork, SHARED)))
      fs.cpSync(path.join(pagesWork, SHARED), path.join(options.out, SHARED), { recursive: true });
    fs.writeFileSync(path.join(options.out, SHARED, shared.name), shared.bytes);
    for (const page of options.pages) {
      const { outputs, outputPath } = pages;
      const dir = path.join(options.out, page);
      const entryFile = entryOutput(outputs, path.join(root, page, "main.tsx"), page);
      const entry = path.basename(entryFile);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true });
      const entryCode = fs.readFileSync(path.join(pagesWork, entryFile), "utf8");
      const named = nameChunksBySharedOrigin(entryCode, outputs[entryFile].imports);
      fs.writeFileSync(path.join(dir, entry), named);
      const firstLoad = closure(outputs, entryFile, STATIC);
      const libraryUrls = externalImports(outputs, firstLoad);
      logFirstLoad(page, outputs, firstLoad, libraryUrls);
      const preload = [...firstLoad.slice(1).map(sharedUrl), ...libraryUrls];
      const cssBundle = outputs[entryFile].cssBundle;
      const css = cssBundle ? fs.readFileSync(path.join(pagesWork, outputPath(cssBundle)), "utf8").trimEnd() : "";
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
      fs.writeFileSync(path.join(dir, "index.html"), pageHtml({ page, entry, preload, loader, css }));
    }
    // The pane's <style> is build-agent-pane-web.sh's (dev.tsx's sheets, then Tailwind), not its
    // entry's stylesheet, which is left out.
    if (agentPane) {
      const { outputs } = pane;
      const entryFile = entryOutput(outputs, agentPane.entry, AGENT_PANE);
      fs.rmSync(agentPane.out, { recursive: true, force: true });
      for (const file of Object.keys(outputs).filter((file) => file.endsWith(".js"))) {
        fs.mkdirSync(path.dirname(path.join(agentPane.out, file)), { recursive: true });
        fs.copyFileSync(path.join(paneWork, file), path.join(agentPane.out, file));
      }
      const firstLoad = closure(outputs, entryFile, STATIC);
      const libraryUrls = externalImports(outputs, firstLoad);
      logFirstLoad(AGENT_PANE, outputs, firstLoad, libraryUrls);
      const links = modulepreloadLinks(entryFile, [...firstLoad.slice(1), ...libraryUrls]);
      fs.writeFileSync(path.join(agentPane.out, "preload.html"), links.join("\n") + "\n");
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
 *
 * `agentPane` (`{ dir, html }`) also checks the agent pane's document `html` in its own folder `dir`
 * (cmux.agent, outside the tree, with its own chunks) on the app's origins: the daemon serves no
 * agent pane.
 */
export function checkPageTree(root, pages, agentPane) {
  const problems = [];
  const fileOf = (location) =>
    agentPane && location.root === AGENT_PANE
      ? path.join(agentPane.dir, location.url)
      : path.join(root, treeFile(location));
  const exists = (location) => fs.existsSync(fileOf(location)) && fs.statSync(fileOf(location)).isFile();
  const documents = pages.map((page) => ({
    name: page,
    servers: SERVERS.map((server) => ({ ...server, document: server.document(page) })),
  }));
  if (agentPane)
    documents.push({
      name: AGENT_PANE,
      servers: [{ ...SERVERS[0], document: { root: AGENT_PANE, url: agentPane.html } }],
    });
  for (const { name: page, servers } of documents) {
    const htmlFile = fileOf(servers[0].document);
    const htmlName = treeFile(servers[0].document);
    if (!fs.existsSync(htmlFile)) {
      problems.push(`${page}: no ${path.posix.basename(htmlName)}`);
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
      if (tag.script && !tag.source) problems.push(`${htmlName}: inline script`);
      if (tag.inline) problems.push(`${htmlName}: a script with inline code`);
    }
    if (!tags.some((tag) => tag.module && tag.source)) problems.push(`${htmlName}: no module script`);
    for (const server of servers) {
      const scripts = [];
      const reach = (from, specifier) => {
        const location = locate(server, from, specifier);
        if (!location || !exists(location)) {
          problems.push(`${treeFile(from)}: ${specifier} is not on ${server.name}`);
          return undefined;
        }
        return location;
      };
      const document = server.document;
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
        for (const [, specifier] of fs.readFileSync(fileOf(location), "utf8").matchAll(IMPORT)) {
          const next = reach(location, specifier);
          if (next) scripts.push(next);
          // A chunk on a page's own origin would have a different URL on every page. The pane's
          // chunks are its own run's, which no page imports.
          if (next && next.root === page && page !== AGENT_PANE)
            problems.push(`${treeFile(location)}: ${specifier} is not on ${SHARED_ORIGIN}`);
        }
      }
    }
  }
  return problems;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const options = parseArgs(process.argv.slice(2));
  if (!options.checkOnly) await buildPages(options);
  // A build checks the pane's first load (preload.html); --check-only the page written around it.
  const problems = checkPageTree(
    options.out,
    options.pages,
    options.agentPane && { dir: options.agentPane.out, html: options.checkOnly ? "index.html" : "preload.html" },
  );
  if (problems.length) {
    for (const problem of problems) console.error(`error: ${problem}`);
    process.exit(1);
  }
}
