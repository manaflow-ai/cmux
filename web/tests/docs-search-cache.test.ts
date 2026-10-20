import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "./helpers/run-child";

const webRoot = fileURLToPath(new URL("..", import.meta.url));
let fixture: string | undefined;

afterEach(() => {
  if (fixture) rmSync(fixture, { recursive: true, force: true });
  fixture = undefined;
});

/** Builds the docs search index in the fixture and returns its stdout; throws on failure. */
async function build(web: string) {
  const result = await runChild(process.execPath, ["tools/build-docs-search.mjs"], {
    cwd: web,
    timeout: 60_000,
    env: { ...process.env, CMUX_DOCS_CHANNEL: "release" },
  });
  if (result.status !== 0) {
    throw new Error(`Docs index failed: ${result.stderr}\n${result.stdout}`);
  }
  return result.stdout;
}

function outputHashes(directory: string): Record<string, string> {
  const hashes: Record<string, string> = {};
  for (const entry of readdirSync(directory, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile()) continue;
    const file = path.join(entry.parentPath, entry.name);
    hashes[path.relative(directory, file)] = createHash("sha256")
      .update(readFileSync(file))
      .digest("hex");
  }
  return hashes;
}

test("restores identical search assets and rebuilds after dependency or generator changes", async () => {
  fixture = mkdtempSync(path.join(tmpdir(), "cmux-docs-cache-"));
  const web = path.join(fixture, "web");
  mkdirSync(path.join(web, "tools"), { recursive: true });
  for (const directory of ["app", "i18n", "messages", "node_modules"]) {
    symlinkSync(path.join(webRoot, directory), path.join(web, directory), "dir");
  }
  const script = path.join(web, "tools", "build-docs-search.mjs");
  copyFileSync(path.join(webRoot, "tools", "build-docs-search.mjs"), script);
  copyFileSync(path.join(webRoot, "bun.lock"), path.join(web, "bun.lock"));
  copyFileSync(path.join(webRoot, "..", "CHANGELOG.md"), path.join(fixture, "CHANGELOG.md"));

  const restored = "Docs search index restored";
  const output = path.join(web, "public", "pagefind");
  expect(await build(web)).not.toContain(restored);
  const original = outputHashes(output);
  expect(Object.keys(original)).toContain("pagefind.js");
  rmSync(output, { recursive: true });
  expect(await build(web)).toContain(restored);
  expect(outputHashes(output)).toEqual(original);

  appendFileSync(path.join(web, "bun.lock"), "\n");
  expect(await build(web)).not.toContain(restored);
  expect(await build(web)).toContain(restored);

  appendFileSync(script, "\n// Updated generator revision.\n");
  expect(await build(web)).not.toContain(restored);

  appendFileSync(path.join(fixture, "CHANGELOG.md"), "\nA new searchable release note.\n");
  expect(await build(web)).not.toContain(restored);
  expect(outputHashes(output)).not.toEqual(original);
}, 120_000);
