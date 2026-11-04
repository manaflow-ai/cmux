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

test("without CMUX_VITE_TRANSFORM_CACHE the compiler writes no cache", async () => {
  const before = entries().length;
  fs.writeFileSync(source, "export function Greeting() { return <p>Hi</p>; }\n");
  expect(await compile(undefined)).toContain("const $ = _c(");
  expect(entries()).toHaveLength(before);
});
