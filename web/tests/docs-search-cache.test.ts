import { afterEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
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

const webRoot = fileURLToPath(new URL("..", import.meta.url));
let fixture: string | undefined;

afterEach(() => {
  if (fixture) rmSync(fixture, { recursive: true, force: true });
  fixture = undefined;
});

function build(web: string) {
  const result = spawnSync(process.execPath, ["tools/build-docs-search.mjs"], {
    cwd: web,
    encoding: "utf8",
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

test("restores identical search assets and rebuilds after dependency or generator changes", () => {
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
  expect(build(web)).not.toContain(restored);
  const original = outputHashes(output);
  expect(Object.keys(original)).toContain("pagefind.js");
  rmSync(output, { recursive: true });
  expect(build(web)).toContain(restored);
  expect(outputHashes(output)).toEqual(original);

  appendFileSync(path.join(web, "bun.lock"), "\n");
  expect(build(web)).not.toContain(restored);
  expect(build(web)).toContain(restored);

  appendFileSync(script, "\n// Updated generator revision.\n");
  expect(build(web)).not.toContain(restored);

  appendFileSync(path.join(fixture, "CHANGELOG.md"), "\nA new searchable release note.\n");
  expect(build(web)).not.toContain(restored);
  expect(outputHashes(output)).not.toEqual(original);
}, { timeout: 120_000 });
