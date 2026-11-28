// The React Compiler pass keeps its output in CMUX_VITE_TRANSFORM_CACHE (reactCompiler.mjs), which
// scripts/ci/run-webviews-tests.sh sets for a whole run: each dev server test file compiled the agent
// pane again in its own Vite (App.tsx alone took 33 s), and that put dev server files over their
// limits on busy shards (2026-11-04). A second Vite on the same cache reads the first one's output,
// a changed module compiles again, and with no cache set nothing is written anywhere.
import { afterAll, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { createServer } from "vite";
import { reactWithCompiler } from "../reactCompiler.mjs";

// Inside webviews/ (git ignores tmp-*/), so the module resolves react/compiler-runtime from its node_modules.
const scratch = fs.mkdtempSync(path.join(import.meta.dir, "..", "tmp-react-compiler-cache-"));
const source = path.join(scratch, "Greeting.tsx");
const cache = path.join(scratch, "cache");
const saved = process.env.CMUX_VITE_TRANSFORM_CACHE;

afterAll(() => {
  if (saved === undefined) delete process.env.CMUX_VITE_TRANSFORM_CACHE;
  else process.env.CMUX_VITE_TRANSFORM_CACHE = saved;
  fs.rmSync(scratch, { recursive: true, force: true });
});

const entries = () =>
  fs.existsSync(cache)
    ? fs.readdirSync(cache, { recursive: true }).filter((name) => String(name).endsWith(".json"))
    : [];

/** One fresh Vite with the React Compiler, as a dev server test file starts one; the compiled module. */
const compile = async (dir: string | undefined): Promise<string> => {
  // reactWithCompiler reads the cache folder when it makes the plugin.
  if (dir === undefined) delete process.env.CMUX_VITE_TRANSFORM_CACHE;
  else process.env.CMUX_VITE_TRANSFORM_CACHE = dir;
  const server = await createServer({
    configFile: false,
    root: scratch,
    cacheDir: path.join(scratch, "vite"),
    plugins: reactWithCompiler(),
    server: { middlewareMode: true, hmr: false, ws: false, preTransformRequests: false },
    optimizeDeps: { noDiscovery: true, include: [] },
    logLevel: "error",
  });
  try {
    return (await server.transformRequest("/Greeting.tsx"))!.code;
  } finally {
    await server.close();
  }
};

test("a second Vite on the run's cache reads the React Compiler output the first one wrote", async () => {
  fs.writeFileSync(source, "export function Greeting({ name }: { name: string }) { return <p>Hi {name}</p>; }\n");
  const first = await compile(cache);
  expect(first).toContain("const $ = _c(");
  const written = entries();
  expect(written).toHaveLength(1);
  // Mark the stored output: a second server that ran the compiler again would not return the mark.
  const file = path.join(cache, String(written[0]));
  const stored = JSON.parse(fs.readFileSync(file, "utf8")) as { code: string };
  fs.writeFileSync(file, JSON.stringify({ ...stored, code: `${stored.code}\n// read from the cache` }));
  expect(await compile(cache)).toContain("// read from the cache");

  // A changed module is a new key: it compiles again and gets an entry of its own.
  fs.writeFileSync(source, "export function Greeting({ name }: { name: string }) { return <p>Hello {name}</p>; }\n");
  const changed = await compile(cache);
  expect(changed).toContain("Hello");
  expect(changed).not.toContain("// read from the cache");
  expect(entries()).toHaveLength(2);
});

// CI keeps one cache across runs (ci-web.yml's react-apps-check shards), and each run checks out to its own path:
// a key on the absolute module id missed every entry another checkout wrote. Two copies of webviews/ (this
// file's reactCompiler.mjs in each) stand in for two checkouts; the second reads the first one's entry.
test("a cache written in one checkout is read in another", async () => {
  const shared = path.join(scratch, "shared-cache");
  const checkouts = ["checkout-a", "checkout-b"].map((name) => {
    const root = path.join(scratch, name);
    fs.mkdirSync(path.join(root, "dev-server"), { recursive: true });
    fs.mkdirSync(path.join(root, "src"), { recursive: true });
    for (const file of ["reactCompiler.mjs", "bun.lock", "dev-server/viteCacheDir.mjs"]) {
      fs.copyFileSync(path.join(import.meta.dir, "..", file), path.join(root, file));
    }
    fs.writeFileSync(
      path.join(root, "src", "Card.tsx"),
      "export function Card({ title }: { title: string }) { return <h2>{title}</h2>; }\n",
    );
    return root;
  });
  const compileIn = async (root: string): Promise<string> => {
    process.env.CMUX_VITE_TRANSFORM_CACHE = shared;
    const { reactWithCompiler: plugins } = await import(path.join(root, "reactCompiler.mjs"));
    const server = await createServer({
      configFile: false,
      root,
      cacheDir: path.join(root, "vite"),
      plugins: plugins(),
      server: { middlewareMode: true, hmr: false, ws: false, preTransformRequests: false },
      optimizeDeps: { noDiscovery: true, include: [] },
      logLevel: "error",
    });
    try {
      return (await server.transformRequest("/src/Card.tsx"))!.code;
    } finally {
      await server.close();
    }
  };
  expect(await compileIn(checkouts[0]!)).toContain("const $ = _c(");
  const written = fs.readdirSync(shared, { recursive: true }).filter((name) => String(name).endsWith(".json"));
  expect(written).toHaveLength(1);
  const file = path.join(shared, String(written[0]));
  const stored = JSON.parse(fs.readFileSync(file, "utf8")) as { code: string };
  fs.writeFileSync(file, JSON.stringify({ ...stored, code: `${stored.code}\n// from checkout-a` }));
  // A day-old entry: a hit marks it as read, so CI's prune keeps what runs still use.
  const old = new Date(Date.now() - 86_400_000);
  fs.utimesSync(file, old, old);
  expect(await compileIn(checkouts[1]!)).toContain("// from checkout-a");
  expect(fs.statSync(file).mtimeMs).toBeGreaterThan(old.getTime() + 3_600_000);
});

test("without CMUX_VITE_TRANSFORM_CACHE the compiler writes no cache", async () => {
  const before = entries().length;
  fs.writeFileSync(source, "export function Greeting() { return <p>Hi</p>; }\n");
  expect(await compile(undefined)).toContain("const $ = _c(");
  expect(entries()).toHaveLength(before);
});
