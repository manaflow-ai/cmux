// The split page build (scripts/pages/build-pages.mjs): each page's index.html has no inline
// script, every page names its shared chunks by the one shared origin (cmux-page://cmux.shared/),
// and every script, modulepreload and import resolves in the app (the page's own cmux-page://
// origin serves its folder, cmux.shared serves _shared/) and on the daemon's /pages/ (the tree).
// The full build runs in build-pages-web.sh --check; this covers the tree check on small trees and
// the build on two fixture pages (test/fixtures/pages-split).
import { afterEach, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  AGENT_PANE,
  SHARED_ORIGIN,
  buildPages,
  checkPageTree,
  nameChunksBySharedOrigin,
  pageHtml,
} from "../scripts/pages/build-pages.mjs";
import { SHARED_PATH, builtPageFile, withSharedChunksHere } from "../scripts/pages/shared-origin.mjs";

const trees: string[] = [];
afterEach(() => {
  for (const tree of trees.splice(0)) fs.rmSync(tree, { recursive: true, force: true });
});

function tempDir(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pages-split-build-"));
  trees.push(root);
  return root;
}

/** A built tree: `files` maps a path under the tree to its contents. */
function tree(files: Record<string, string>): string {
  const root = tempDir();
  for (const [file, contents] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), contents);
  }
  return root;
}

const html = pageHtml({
  page: "history",
  entry: "app-H.js",
  preload: [`${SHARED_ORIGIN}chunk-A.js`],
  loader: "",
  css: ":root{}",
});
const entry = `import{a}from"${SHARED_ORIGIN}chunk-A.js";a();import("${SHARED_ORIGIN}lazy-L.js");`;
const chunk = 'import{b}from"./chunk-B.js";export const a=b;';
const whole = {
  "history/index.html": html,
  "history/app-H.js": entry,
  "_shared/chunk-A.js": chunk,
  "_shared/chunk-B.js": "export const b=()=>{};",
  "_shared/lazy-L.js": "export default 1;",
};
const APP = "the app's cmux-page:// origins";
const DAEMON = "the daemon's /pages/";

describe("split page build", () => {
  test("the page preloads its entry and its shared chunks by the shared origin, and runs no inline script", () => {
    expect(html).toContain('<link rel="modulepreload" href="app-H.js" />');
    expect(html).toContain('<link rel="modulepreload" href="cmux-page://cmux.shared/chunk-A.js" />');
    expect(html).toContain('<script type="module" src="app-H.js"></script>');
    expect(html).not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/);
  });

  test("a whole tree has no problems", () => {
    expect(checkPageTree(tree(whole), ["history"])).toEqual([]);
  });

  test("a chunk missing from the shared folder fails in the app and on the daemon", () => {
    const { ["_shared/chunk-B.js"]: _, ...files } = whole;
    expect(checkPageTree(tree(files), ["history"])).toEqual([
      `_shared/chunk-A.js: ./chunk-B.js is not on ${APP}`,
      `_shared/chunk-A.js: ./chunk-B.js is not on ${DAEMON}`,
    ]);
  });

  test("a chunk named relative to the page has one URL per page and fails", () => {
    // The layout before the shared origin: each page imports its own copy of the chunks.
    const relative = {
      "history/index.html": html.replace(`${SHARED_ORIGIN}chunk-A.js`, "../_shared/chunk-A.js"),
      "history/app-H.js": 'import{a}from"../_shared/chunk-A.js";a();',
      "history/_shared/chunk-A.js": chunk,
      "history/_shared/chunk-B.js": "export const b=()=>{};",
      "_shared/chunk-A.js": chunk,
      "_shared/chunk-B.js": "export const b=()=>{};",
    };
    expect(checkPageTree(tree(relative), ["history"]).sort()).toEqual([
      `history/_shared/chunk-A.js: ./chunk-B.js is not on ${SHARED_ORIGIN}`,
      `history/app-H.js: ../_shared/chunk-A.js is not on ${SHARED_ORIGIN}`,
    ]);
  });

  test("inline module code fails", () => {
    const inline = html.replace(
      '<script type="module" src="app-H.js"></script>',
      '<script type="module">run()</script>',
    );
    expect(checkPageTree(tree({ ...whole, "history/index.html": inline }), ["history"])).toEqual([
      "history/index.html: inline script",
      "history/index.html: a script with inline code",
    ]);
  });

  test("a preload of a file that is not there fails", () => {
    const stale = html.replace("chunk-A.js", "chunk-OLD.js");
    expect(checkPageTree(tree({ ...whole, "history/index.html": stale }), ["history"])).toEqual([
      `history/index.html: ${SHARED_ORIGIN}chunk-OLD.js is not on ${APP}`,
      `history/index.html: ${SHARED_ORIGIN}chunk-OLD.js is not on ${DAEMON}`,
    ]);
  });

  test("a page with no index.html fails", () => {
    expect(checkPageTree(tree(whole), ["history", "stats"])).toEqual(["stats: no index.html"]);
  });

  test("an entry names exactly its shared imports by the shared origin", () => {
    const code = 'import"../_shared/a-1.js";import("../_shared/b-2.js");const s="../_shared/c-3.js";';
    const imports = [{ path: "_shared/a-1.js" }, { path: "_shared/b-2.js" }];
    expect(nameChunksBySharedOrigin(code, imports)).toBe(
      `import"${SHARED_ORIGIN}a-1.js";import("${SHARED_ORIGIN}b-2.js");const s="../_shared/c-3.js";`,
    );
  });

  /** The one shared-origin URL that holds React among the preloads of `html` and its entry's imports in `dir`. */
  function reactUrl(out: string, dir: string, html: string): string | undefined {
    expect(fs.existsSync(path.join(dir, "_shared"))).toBe(false);
    const entryFile = fs.readdirSync(dir).find((file) => file.endsWith(".js"));
    const named = [
      ...fs.readFileSync(path.join(dir, html), "utf8").matchAll(/href="([^"]+)"/g),
      ...fs.readFileSync(path.join(dir, entryFile ?? ""), "utf8").matchAll(/"(cmux-page:[^"]+)"/g),
    ].map((match) => match[1]);
    const react = [...new Set(named)].filter(
      (url) =>
        url.startsWith(SHARED_ORIGIN) &&
        /react\.(?:transitional\.)?element/.test(
          fs.readFileSync(path.join(out, "_shared", url.slice(SHARED_ORIGIN.length)), "utf8"),
        ),
    );
    expect(react).toHaveLength(1);
    return react[0];
  }

  test("every built page loads React from one shared-origin URL", async () => {
    const out = tempDir();
    const pagesRoot = path.join(import.meta.dir, "fixtures/pages-split");
    await buildPages({ out, pages: ["alpha", "beta"], pagesRoot });
    expect(checkPageTree(out, ["alpha", "beta"])).toEqual([]);
    const reactUrls = ["alpha", "beta"].map((page) => reactUrl(out, path.join(out, page), "index.html"));
    expect(reactUrls[0]).toStartWith(SHARED_ORIGIN);
    expect(reactUrls[1]).toBe(reactUrls[0]);
  }, 60_000);

  /** Every file under `dir`, by its path under `dir`, with its bytes. */
  function treeFiles(dir: string): Record<string, string> {
    const files: Record<string, string> = {};
    const walk = (folder: string) => {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const file = path.join(folder, entry.name);
        if (entry.isDirectory()) walk(file);
        else files[path.relative(dir, file)] = fs.readFileSync(file, "utf8");
      }
    };
    walk(dir);
    return files;
  }

  test("the agent pane loads React from the pages' library URL and never changes what a page loads", async () => {
    const pagesRoot = path.join(import.meta.dir, "fixtures/pages-split");
    const entry = path.join(import.meta.dir, "fixtures/pages-split-agent/main.tsx");
    const alone = tempDir();
    await buildPages({ out: alone, pages: ["alpha", "beta"], pagesRoot });
    const out = tempDir();
    const pane = path.join(tempDir(), "scripts");
    await buildPages({ out, pages: ["alpha", "beta"], pagesRoot, agentPane: { entry, out: pane } });
    // The pages are the same files, byte for byte, with the pane built or not: what only the pane
    // imports (util's forPane, alpha's lazy module) never reaches a page's chunks.
    expect(treeFiles(out)).toEqual(treeFiles(alone));
    expect(Object.values(treeFiles(out)).join("\n")).not.toContain(".repeat(64)");
    // The pane's folder: its entry, its own chunks and its first-load preloads, nothing for the tree.
    const files = fs.readdirSync(pane).sort();
    expect(files).toHaveLength(3);
    expect(files[0]).toMatch(/^app-[A-Z0-9]+\.js$/);
    expect(files.slice(1)).toEqual(["chunks", "preload.html"]);
    const paneCode = Object.values(treeFiles(pane)).join("\n");
    expect(paneCode).toContain(".repeat(64)");
    expect(fs.readFileSync(path.join(pane, files[0]), "utf8")).toMatch(/import\("\.\/chunks\/lazy-[A-Z0-9]+\.js"\)/);
    expect(fs.existsSync(path.join(out, AGENT_PANE))).toBe(false);
    const preload = fs.readFileSync(path.join(pane, "preload.html"), "utf8");
    expect(preload.split("\n")[0]).toBe(`<link rel="modulepreload" href="${files[0]}" />`);
    expect(checkPageTree(out, ["alpha", "beta"], { dir: pane, html: "preload.html" })).toEqual([]);
    const pageReact = reactUrl(out, path.join(out, "alpha"), "index.html");
    expect(pageReact).toMatch(/^cmux-page:\/\/cmux\.shared\/react-[A-Z0-9]+\.js$/);
    expect(reactUrl(out, pane, "preload.html")).toBe(pageReact);
  }, 60_000);

  test("the agent pane's page resolves its own files on cmux.agent and the library on cmux.shared", () => {
    const library = `${SHARED_ORIGIN}react-R.js`;
    const pane = tree({
      "index.html": [
        '<link rel="modulepreload" href="app-P.js" />',
        '<link rel="modulepreload" href="chunks/own-C.js" />',
        `<link rel="modulepreload" href="${library}" />`,
        '<script src="locales/en.js"></script>',
        '<script type="module" src="app-P.js"></script>',
      ].join("\n"),
      "app-P.js": `import{c}from"./chunks/own-C.js";import{createElement as e}from"${library}";e(c);`,
      "chunks/own-C.js": `import{jsx as j}from"${library}";export const c=j;`,
      "locales/en.js": "self.strings={};",
    });
    const pages = tree({ ...whole, "_shared/react-R.js": "export const createElement=()=>{},jsx=()=>{};" });
    const agentPane = { dir: pane, html: "index.html" };
    expect(checkPageTree(pages, [], agentPane)).toEqual([]);
    // A chunk of the pane's own goes missing.
    fs.rmSync(path.join(pane, "chunks/own-C.js"));
    expect(checkPageTree(pages, [], agentPane)).toEqual([
      `${AGENT_PANE}/index.html: chunks/own-C.js is not on ${APP}`,
      `${AGENT_PANE}/app-P.js: ./chunks/own-C.js is not on ${APP}`,
    ]);
    // The library is missing from the pages' shared folder; the daemon serves no agent pane.
    fs.writeFileSync(path.join(pane, "chunks/own-C.js"), `import{jsx as j}from"${library}";export const c=j;`);
    fs.rmSync(path.join(pages, "_shared/react-R.js"));
    expect(checkPageTree(pages, [], agentPane)).toEqual([
      `${AGENT_PANE}/index.html: ${library} is not on ${APP}`,
      `${AGENT_PANE}/app-P.js: ${library} is not on ${APP}`,
      `${AGENT_PANE}/chunks/own-C.js: ${library} is not on ${APP}`,
    ]);
    expect(checkPageTree(pages, [], { dir: tempDir(), html: "index.html" })).toEqual([`${AGENT_PANE}: no index.html`]);
  });
});

describe("a loopback server of a built page", () => {
  test("answers the page's folder and the shared chunks at /_shared/, nothing outside them", () => {
    const page = tree({ "index.html": "<p></p>", "app-P.js": "" });
    const shared = tree({ "chunk-A.js": "" });
    const files = { page, shared };
    expect(builtPageFile("/", files)).toBe(path.join(page, "index.html"));
    expect(builtPageFile("/app-P.js", files)).toBe(path.join(page, "app-P.js"));
    expect(builtPageFile(`${SHARED_PATH}chunk-A.js`, files)).toBe(path.join(shared, "chunk-A.js"));
    expect(builtPageFile("/chunk-A.js", files)).toBeUndefined();
    expect(builtPageFile(`${SHARED_PATH}../${path.basename(page)}/app-P.js`, files)).toBeUndefined();
    expect(builtPageFile("/%2e%2e/etc/passwd", files)).toBeUndefined();
    expect(builtPageFile(SHARED_PATH, files)).toBeUndefined();
  });

  test("names every shared chunk by its path there, as the daemon's /pages/ does", () => {
    expect(
      withSharedChunksHere(`import"${SHARED_ORIGIN}a.js";<meta content="script-src cmux-page://cmux.shared">`),
    ).toBe(`import"${SHARED_PATH}a.js";<meta content="script-src cmux-page://cmux.shared">`);
  });
});

describe("the shared React (cmux-page://cmux.shared/)", () => {
  const REACT = `${SHARED_ORIGIN}react-R.js`;
  const sharedHtml = pageHtml({
    page: "history",
    entry: "app-H.js",
    preload: [`${SHARED_ORIGIN}chunk-A.js`, REACT],
    loader: "",
    css: "",
  });
  const sharedEntry = `import{react$useState as u}from"${REACT}";import{a}from"${SHARED_ORIGIN}chunk-A.js";a(u);`;
  const withReact = {
    ...whole,
    "history/index.html": sharedHtml,
    "history/app-H.js": sharedEntry,
    "_shared/react-R.js": "export const react$useState=()=>{};",
  };

  test("an import and a preload of the shared React file resolve", () => {
    expect(checkPageTree(tree(withReact), ["history"])).toEqual([]);
  });

  test("a React file the tree's _shared lacks fails, for the preload and the import, on both servers", () => {
    const { ["_shared/react-R.js"]: _, ...files } = withReact;
    expect(checkPageTree(tree(files), ["history"])).toEqual([
      `history/index.html: ${REACT} is not on ${APP}`,
      `history/app-H.js: ${REACT} is not on ${APP}`,
      `history/index.html: ${REACT} is not on ${DAEMON}`,
      `history/app-H.js: ${REACT} is not on ${DAEMON}`,
    ]);
  });
});
