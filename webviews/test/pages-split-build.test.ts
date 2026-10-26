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
  SHARED_ORIGIN,
  buildPages,
  checkPageTree,
  nameChunksBySharedOrigin,
  pageHtml,
} from "../scripts/pages/build-pages.mjs";

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

  test("every built page loads React from one shared-origin URL", async () => {
    const out = tempDir();
    const pagesRoot = path.join(import.meta.dir, "fixtures/pages-split");
    await buildPages({ out, pages: ["alpha", "beta"], pagesRoot });
    expect(checkPageTree(out, ["alpha", "beta"])).toEqual([]);
    const reactUrls = ["alpha", "beta"].map((page) => {
      expect(fs.existsSync(path.join(out, page, "_shared"))).toBe(false);
      const entryFile = fs.readdirSync(path.join(out, page)).find((file) => file.endsWith(".js"));
      const named = [
        ...fs.readFileSync(path.join(out, page, "index.html"), "utf8").matchAll(/href="([^"]+)"/g),
        ...fs.readFileSync(path.join(out, page, entryFile ?? ""), "utf8").matchAll(/"(cmux-page:[^"]+)"/g),
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
    });
    expect(reactUrls[0]).toStartWith(SHARED_ORIGIN);
    expect(reactUrls[1]).toBe(reactUrls[0]);
  }, 60_000);
});
