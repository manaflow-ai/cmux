// The agent pane's classic-script pass (scripts/agent-pane/classicScript.mjs) must build when its output folder is
// reached through a symlink. macOS's `mktemp -d` (scripts/cmux-next/build-agent-pane-web.sh) and /tmp are under
// /var and /tmp, links to /private/var and /private/tmp. esbuild resolves a lazy chunk's imports against the
// real path, so the pass took every static chunk for a lazy one and left `import "./chunk-…"` in the lazy
// chunks: "classic pane: chunks/typingLoadDebug-….js still names the static chunk chunks/chunk-….js" on every
// macOS build (feat-cmux-next 0e481bff), while Linux, with no such link, built.
import { afterAll, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import vm from "node:vm";
import { build } from "esbuild";
import { classicScript } from "../scripts/agent-pane/classicScript.mjs";

const root = realpathSync(mkdtempSync(path.join(tmpdir(), "agent-pane-classic-")));
afterAll(() => rmSync(root, { recursive: true, force: true }));

/** Splits a tiny pane (an entry, a module it and its lazy chunk share, the lazy chunk) into `outdir` as bundle.mjs
 * --split does, then runs the classic pass on it. Returns the lazy chunks' text. */
async function buildPane(outdir: string): Promise<string[]> {
  const src = path.join(root, "src");
  mkdirSync(src, { recursive: true });
  writeFileSync(
    path.join(src, "shared.js"),
    "export const shared = () => globalThis.sharedCalls = (globalThis.sharedCalls ?? 0) + 1;\n",
  );
  writeFileSync(
    path.join(src, "lazy.js"),
    'import { shared } from "./shared.js";\nexport const lazy = () => shared();\n',
  );
  writeFileSync(
    path.join(src, "main.js"),
    'import { shared } from "./shared.js";\nshared();\nexport const load = () => import("./lazy.js");\n',
  );
  const outfile = path.join(outdir, "pane.js");
  const result = await build({
    entryPoints: [path.join(src, "main.js")],
    bundle: true,
    format: "esm",
    splitting: true,
    outdir,
    entryNames: "pane",
    chunkNames: "chunks/[name]-[hash]",
    metafile: true,
    logLevel: "silent",
  });
  const outputs = result.metafile.outputs;
  const entryOut = Object.keys(outputs).find((output) => path.resolve(output) === path.resolve(outfile));
  if (!entryOut) throw new Error("no entry output");
  const staticOut = (outputs[entryOut].imports ?? [])
    .filter((item) => item.kind === "import-statement" && !item.external)
    .map((item) => item.path);
  expect(staticOut.length).toBeGreaterThan(0);
  await classicScript({ outdir: path.resolve(outdir), outputs, staticOut, entryOut, maps: false });
  const chunks = path.join(outdir, "chunks");
  return readdirSync(chunks)
    .filter((name) => name.endsWith(".js"))
    .map((name) => readFileSync(path.join(chunks, name), "utf8"));
}

test("the classic pass builds in a real folder", async () => {
  const lazy = await buildPane(path.join(root, "real", "pane"));
  expect(lazy.length).toBe(1);
  expect(lazy[0]).not.toContain("./chunk-");
});

test("the classic pass builds through a symlinked folder (macOS mktemp, /tmp)", async () => {
  mkdirSync(path.join(root, "target", "pane"), { recursive: true });
  symlinkSync(path.join(root, "target"), path.join(root, "link"));
  const lazy = await buildPane(path.join(root, "link", "pane"));
  expect(lazy.length).toBe(1);
  expect(lazy[0]).not.toContain("./chunk-");
});

// shiki's grammars are lazy chunks a lazy chunk (the highlighter) loads with import(). The pass wrote every import()
// as `./chunks/<name>`, right from pane.js but resolved from chunks/ itself to chunks/chunks/<name>: the agent pane
// logged "Failed to fetch dynamically imported module: cmux-page://cmux.agent/chunks/chunks/typescript-….js" and
// highlighted no code block (found by the hot-verify look's page log, cmux#64758).
test("a lazy chunk's import() of another lazy chunk resolves from that chunk's folder", async () => {
  const src = path.join(root, "nested-src");
  mkdirSync(src, { recursive: true });
  writeFileSync(path.join(src, "shared.js"), "export const shared = () => 1;\n");
  writeFileSync(path.join(src, "grammar.js"), "export default { name: 'typescript' };\n");
  writeFileSync(
    path.join(src, "highlighter.js"),
    'import { shared } from "./shared.js";\nexport const grammar = () => (shared(), import("./grammar.js"));\n',
  );
  writeFileSync(
    path.join(src, "main.js"),
    'import { shared } from "./shared.js";\nshared();\nglobalThis.load = () => import("./highlighter.js");\n',
  );
  const outdir = path.join(root, "nested", "pane");
  const result = await build({
    entryPoints: [path.join(src, "main.js")],
    bundle: true,
    format: "esm",
    splitting: true,
    outdir,
    entryNames: "pane",
    chunkNames: "chunks/[name]-[hash]",
    metafile: true,
    logLevel: "silent",
  });
  const outputs = result.metafile.outputs;
  const entryOut = Object.keys(outputs).find((output) => path.resolve(output) === path.join(outdir, "pane.js"));
  if (!entryOut) throw new Error("no entry output");
  const staticOut = (outputs[entryOut].imports ?? [])
    .filter((item) => item.kind === "import-statement" && !item.external)
    .map((item) => item.path);
  await classicScript({ outdir, outputs, staticOut, entryOut, maps: false });

  const scripts = [
    path.join(outdir, "pane.js"),
    ...readdirSync(path.join(outdir, "chunks"))
      .filter((name) => name.endsWith(".js"))
      .map((name) => path.join(outdir, "chunks", name)),
  ];
  const imports = scripts.flatMap((file) =>
    [...readFileSync(file, "utf8").matchAll(/(?:\bimport|__pImp)\(\s*["']([^"']+)["']\s*\)/g)].map((found) => ({
      file,
      target: path.resolve(path.dirname(file), found[1]),
    })),
  );
  // pane.js imports the highlighter, and the highlighter imports the grammar.
  expect(imports.length).toBe(2);
  for (const { file, target } of imports) {
    expect({ file: path.relative(outdir, file), exists: existsSync(target) }).toEqual({
      file: path.relative(outdir, file),
      exists: true,
    });
  }
  expect(imports.some(({ target }) => target.includes(`${path.sep}chunks${path.sep}chunks${path.sep}`))).toBe(false);
});

/** Splits SRC's main.js into OUTDIR as bundle.mjs --split does and runs the classic pass. */
async function splitAndClassic(src: string, outdir: string): Promise<void> {
  const result = await build({
    entryPoints: [path.join(src, "main.js")],
    bundle: true,
    format: "esm",
    splitting: true,
    outdir,
    entryNames: "pane",
    chunkNames: "chunks/[name]-[hash]",
    metafile: true,
    logLevel: "silent",
  });
  const outputs = result.metafile.outputs;
  const entryOut = Object.keys(outputs).find((output) => path.resolve(output) === path.join(outdir, "pane.js"));
  if (!entryOut) throw new Error("no entry output");
  const staticOut = (outputs[entryOut].imports ?? [])
    .filter((item) => item.kind === "import-statement" && !item.external)
    .map((item) => item.path);
  await classicScript({ outdir, outputs, staticOut, entryOut, maps: false });
}

/** Runs OUTDIR's pane.js as the page would, a classic script at BASE, with the flag set to FLAG. A <script> it
 * appends runs from OUTDIR; an import() goes to IMPORTED (the ES module path, which this runner does not load). */
async function runPane(outdir: string, flag: string | null) {
  const base = "cmux-page://cmux.agent/";
  const imported: string[] = [];
  const appended: string[] = [];
  // The page's global object: a bare name in a classic script (__paneLoadRel, __paneChunks) is one of its properties.
  const sandbox: Record<string, unknown> = {
    localStorage: { getItem: (key: string) => (key === "cmux.paneClassicChunks" ? flag : null) },
    __cmuxImport: (url: string) => {
      imported.push(url);
      return Promise.resolve({});
    },
    queueMicrotask,
    Promise,
    URL,
  };
  vm.createContext(sandbox);
  const run = (file: string, src: string) => {
    sandbox.document = {
      currentScript: { src },
      createElement: () => ({}),
      head: {
        appendChild(s: { src: string; onload: () => void }) {
          appended.push(s.src);
          queueMicrotask(() => {
            run(path.join(outdir, s.src.slice(base.length)), s.src);
            s.onload();
          });
        },
      },
    };
    vm.runInContext(readFileSync(file, "utf8").replace(/\bimport\(/g, "__cmuxImport("), sandbox);
  };
  run(path.join(outdir, "pane.js"), `${base}pane.js?h=0`);
  return { sandbox, imported, appended };
}

// The ES module code cache is written and never read, so every lazy chunk compiled again on each cold open. With
// localStorage cmux.paneClassicChunks = "1" pane.js loads each lazy chunk's classic copy (chunks/c/) instead, with
// its shared lazy chunks first and one instance of the static code; off (the default) it imports the ES module.
test("the flag loads the classic copies of the lazy chunks; off, the ES modules", async () => {
  const src = path.join(root, "flag-src");
  mkdirSync(src, { recursive: true });
  writeFileSync(
    path.join(src, "shared.js"),
    "export const shared = () => (globalThis.sharedCalls = (globalThis.sharedCalls ?? 0) + 1);\n",
  );
  writeFileSync(
    path.join(src, "common.js"),
    'import { shared } from "./shared.js";\nexport const common = () => shared() * 10;\n',
  );
  writeFileSync(path.join(src, "grammar.js"), "export default { name: 'typescript' };\n");
  writeFileSync(
    path.join(src, "a.js"),
    'import { common } from "./common.js";\nexport const a = () => common();\nexport const grammar = () => import("./grammar.js");\n',
  );
  writeFileSync(path.join(src, "b.js"), 'import { common } from "./common.js";\nexport const b = () => common();\n');
  writeFileSync(
    path.join(src, "main.js"),
    'import { shared } from "./shared.js";\nshared();\nglobalThis.loadA = () => import("./a.js");\nglobalThis.loadB = () => import("./b.js");\n',
  );
  const outdir = path.join(root, "flag", "pane");
  await splitAndClassic(src, outdir);
  const copies = readdirSync(path.join(outdir, "chunks", "c"));
  // a, b, grammar and the lazy chunk a and b share.
  expect(copies.length).toBe(4);
  for (const name of copies)
    expect(readFileSync(path.join(outdir, "chunks", "c", name), "utf8")).not.toMatch(/\bimport\b|\bexport\b/);

  const on = await runPane(outdir, "1");
  const loadA = on.sandbox.loadA as () => Promise<{
    a: () => number;
    grammar: () => Promise<{ default: { name: string } }>;
  }>;
  const loadB = on.sandbox.loadB as () => Promise<{ b: () => number }>;
  const a = await loadA();
  const b = await loadB();
  // One instance of the static module: the entry's call, then a's and b's.
  expect(a.a()).toBe(20);
  expect(b.b()).toBe(30);
  expect((await a.grammar()).default.name).toBe("typescript");
  expect(on.imported).toEqual([]);
  // The shared lazy chunk once, before a; every script from chunks/c/.
  expect(on.appended.length).toBe(4);
  expect(on.appended.every((src) => src.startsWith("cmux-page://cmux.agent/chunks/c/"))).toBe(true);

  const off = await runPane(outdir, null);
  await (off.sandbox.loadA as () => Promise<unknown>)();
  expect(off.appended).toEqual([]);
  expect(off.imported.length).toBe(1);
  expect(off.imported[0]).toMatch(/^cmux-page:\/\/cmux\.agent\/chunks\/a-[A-Z0-9]+\.js$/);
});
