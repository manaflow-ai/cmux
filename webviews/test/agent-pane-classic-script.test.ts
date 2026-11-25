// The agent pane's classic-script pass (scripts/agent-pane/classicScript.mjs) must build when its output folder is
// reached through a symlink. macOS's `mktemp -d` (scripts/cmux-next/build-agent-pane-web.sh) and /tmp are under
// /var and /tmp, links to /private/var and /private/tmp. esbuild resolves a lazy chunk's imports against the
// real path, so the pass took every static chunk for a lazy one and left `import "./chunk-…"` in the lazy
// chunks: "classic pane: chunks/typingLoadDebug-….js still names the static chunk chunks/chunk-….js" on every
// macOS build (feat-cmux-next 0e481bff), while Linux, with no such link, built.
import { afterAll, expect, test } from "bun:test";
import {
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
  return readdirSync(chunks).map((name) => readFileSync(path.join(chunks, name), "utf8"));
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
