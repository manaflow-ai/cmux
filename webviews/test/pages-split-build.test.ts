// The split page build (scripts/pages/build-pages.mjs): each page's index.html has no inline
// script, and every script, modulepreload and import resolves on the page's own cmux-page://
// origin (its folder is the root) and on the daemon's /pages/<page>/ (the tree is the root).
// The full build runs in build-pages-web.sh --check; this covers the tree check on small trees.
import { afterEach, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checkPageTree, pageHtml } from "../scripts/pages/build-pages.mjs";

const trees: string[] = [];
afterEach(() => {
  for (const tree of trees.splice(0)) fs.rmSync(tree, { recursive: true, force: true });
});

/** A built tree: `files` maps a path under the tree to its contents. */
function tree(files: Record<string, string>): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pages-split-build-"));
  trees.push(root);
  for (const [file, contents] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), contents);
  }
  return root;
}

const html = pageHtml({
  page: "history",
  entry: "app-H.js",
  preload: ["../_shared/chunk-A.js"],
  loader: "",
  css: ":root{}",
});
const entry = 'import{a}from"../_shared/chunk-A.js";a();import("../_shared/lazy-L.js");';
const chunk = 'import{b}from"./chunk-B.js";export const a=b;';
const whole = {
  "history/index.html": html,
  "history/app-H.js": entry,
  "history/_shared/chunk-A.js": chunk,
  "history/_shared/chunk-B.js": "export const b=()=>{};",
  "history/_shared/lazy-L.js": "export default 1;",
  "_shared/chunk-A.js": chunk,
  "_shared/chunk-B.js": "export const b=()=>{};",
  "_shared/lazy-L.js": "export default 1;",
};

describe("split page build", () => {
  test("the page preloads its entry and first-load chunks and runs no inline script", () => {
    expect(html).toContain('<link rel="modulepreload" href="app-H.js" />');
    expect(html).toContain('<link rel="modulepreload" href="../_shared/chunk-A.js" />');
    expect(html).toContain('<script type="module" src="app-H.js"></script>');
    expect(html).not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/);
  });

  test("a whole tree has no problems", () => {
    expect(checkPageTree(tree(whole), ["history"])).toEqual([]);
  });

  test("a chunk missing from the page's own folder fails on its origin", () => {
    const { ["history/_shared/chunk-B.js"]: _, ...files } = whole;
    expect(checkPageTree(tree(files), ["history"])).toEqual([
      "history/_shared/chunk-A.js: ./chunk-B.js is not on the page's origin",
    ]);
  });

  test("a lazy chunk missing from the shared folder fails on the daemon", () => {
    const { ["_shared/lazy-L.js"]: _, ...files } = whole;
    expect(checkPageTree(tree(files), ["history"])).toEqual([
      "history/app-H.js: ../_shared/lazy-L.js is not on the daemon's /pages/",
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
    const stale = html.replace("../_shared/chunk-A.js", "../_shared/chunk-OLD.js");
    expect(checkPageTree(tree({ ...whole, "history/index.html": stale }), ["history"])).toEqual([
      "history/index.html: ../_shared/chunk-OLD.js is not on the page's origin",
      "history/index.html: ../_shared/chunk-OLD.js is not on the daemon's /pages/",
    ]);
  });

  test("a page with no index.html fails", () => {
    expect(checkPageTree(tree(whole), ["history", "stats"])).toEqual(["stats: no index.html"]);
  });
});
