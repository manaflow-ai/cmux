#!/usr/bin/env bun
// Generates webviews/src/protocol/generated/ from the pane protocol IR.
//
//   bun scripts/pane-protocol-codegen.ts            # write
//   bun scripts/pane-protocol-codegen.ts --check    # exit 1 if the committed output drifted
//   bun scripts/pane-protocol-codegen.ts --ir ../cmux-tui/spec/pane-protocol.json
//
// The default IR is the committed seed copy. Point --ir at cmux-tui/spec/pane-protocol.json
// once the Rust emit-ir lands there, then make that the default.

import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { generate } from "../src/protocol/codegen/generate";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(webviewsRoot, "..");
const outDir = path.join(webviewsRoot, "src/protocol/generated");

const args = process.argv.slice(2);
const check = args.includes("--check");
const irIndex = args.indexOf("--ir");
if (irIndex !== -1 && !args[irIndex + 1]) {
  console.error("--ir needs a path");
  process.exit(2);
}
const irPath = path.resolve(
  irIndex === -1 ? path.join(webviewsRoot, "src/protocol/ir/pane-protocol.seed.json") : args[irIndex + 1],
);
const source = path.relative(repoRoot, irPath).split(path.sep).join("/");

const files = generate(JSON.parse(readFileSync(irPath, "utf8")), { source });

if (check) {
  const drift: string[] = [];
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(outDir, name);
    if (!existsSync(file) || readFileSync(file, "utf8") !== content) drift.push(name);
  }
  const extra = existsSync(outDir) ? readdirSync(outDir).filter((name) => !(name in files)) : [];
  if (drift.length > 0 || extra.length > 0) {
    console.error(`pane protocol codegen drift in src/protocol/generated: ${[...drift, ...extra].join(", ")}`);
    console.error("rerun: bun scripts/pane-protocol-codegen.ts");
    process.exit(1);
  }
  console.log(`pane protocol generated code is current (${source})`);
} else {
  mkdirSync(outDir, { recursive: true });
  for (const [name, content] of Object.entries(files)) writeFileSync(path.join(outDir, name), content);
  console.log(`wrote ${Object.keys(files).length} files to src/protocol/generated from ${source}`);
}
