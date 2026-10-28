// A page's lazy sections in the split page build (scripts/pages/section-chunks.mjs, task 081): each
// section loads one file after its page's first load, and making them lazy adds no request to any
// page. The fixture (test/fixtures/pages-sections): gamma loads its sections One and Two with
// import(); they share b with each other only, and c and d with the page delta.
import { afterEach, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { documents, measure } from "../../scripts/cmux-next/page-bundle-report.mjs";
import { buildPages, checkPageTree } from "../scripts/pages/build-pages.mjs";
import { SHARED_ORIGIN } from "../scripts/pages/shared-origin.mjs";

const trees: string[] = [];
afterEach(() => {
  for (const tree of trees.splice(0)) fs.rmSync(tree, { recursive: true, force: true });
});

function tempDir(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pages-section-chunks-"));
  trees.push(root);
  return root;
}

const pagesRoot = path.join(import.meta.dir, "fixtures/pages-sections");
const PAGES = ["gamma", "delta"];

/** Builds the fixture pages; `rows` is what each page's first load and each import() loads. */
async function built() {
  const out = tempDir();
  await buildPages({ out, pages: PAGES, pagesRoot });
  const none = path.join(out, "none");
  const docs = documents({ pages: out, agentPane: none, agentActivity: none, webviewsApp: none }, PAGES);
  const rows = Object.fromEntries(
    docs.slice(0, PAGES.length).map((doc) => [doc.name, measure(doc, path.join(out, "_shared"))]),
  );
  return { out, rows };
}

const name = (url: string) => path.basename(new URL(url).pathname);

test("each section loads one file after its page's first load", async () => {
  const { out, rows } = await built();
  expect(checkPageTree(out, PAGES)).toEqual([]);
  const loads = Object.values(rows.gamma!.lazyLoads as Record<string, string[]>).map((files) => files.map(name));
  expect(loads).toHaveLength(2);
  for (const files of loads) expect(files).toHaveLength(1);
  expect(loads.map(([file]) => file!.replace(/-[A-Z0-9]+\.js$/, "")).sort()).toEqual(["One", "Two"]);
}, 60_000);

test("the sections add no request to another page's first load", async () => {
  const { rows } = await built();
  // delta's entry and one chunk: a, c and d load with the same pages once a section counts as gamma.
  // Without the join, each section split them into a chunk of its own (three).
  expect(rows.delta!.firstLoad.map(name).filter((file: string) => file.startsWith("chunk-"))).toHaveLength(1);
  expect(rows.delta!.requests).toBe(2);
  // gamma's own: its entry, the chunk it shares with delta and the code only its sections share (b).
  expect(rows.gamma!.requests).toBe(3);
}, 60_000);

test("the joined chunks run as the modules they were: one instance each, every export in place", async () => {
  const { out } = await built();
  // Node has no cmux-page:// scheme: name the shared chunks by their folder, as a loopback server does.
  const local = tempDir();
  fs.cpSync(out, local, { recursive: true });
  for (const dir of ["_shared", ...PAGES]) {
    for (const file of fs.readdirSync(path.join(local, dir)).filter((entry) => entry.endsWith(".js"))) {
      const at = path.join(local, dir, file);
      const prefix = dir === "_shared" ? "./" : "../_shared/";
      fs.writeFileSync(at, fs.readFileSync(at, "utf8").replaceAll(SHARED_ORIGIN, prefix));
    }
  }
  const entry = (page: string) =>
    path.join(
      local,
      page,
      fs.readdirSync(path.join(local, page)).find((file) => /^app-.*\.js$/.test(file))!,
    );
  const gamma = await import(pathToFileURL(entry("gamma")).href);
  expect(gamma.gamma).toBe("a:gamma");
  const one = await gamma.sections.one();
  const two = await gamma.sections.two();
  // b counts once per document: both sections run the one copy of it.
  expect(one.one()).toBe("a:one 1 c");
  expect(two.two()).toBe("a:two 2 d");
  const delta = await import(pathToFileURL(entry("delta")).href);
  expect(delta.delta).toBe("a:delta c d");
}, 60_000);
