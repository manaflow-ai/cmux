#!/usr/bin/env bun
// Generates webviews/src/agent-session/acpmux/protocol/generated/ from the acpmux protocol IR.
//
//   bun scripts/acpmux-protocol-codegen.ts            # write
//   bun scripts/acpmux-protocol-codegen.ts --check    # exit 1 if the committed output drifted
//   bun scripts/acpmux-protocol-codegen.ts --ir <path>
//
// The default IR is the daemon's committed emit (`cmux-tui/crates/acpmux/spec/acpmux-protocol.json`),
// which a Rust test keeps in step with `acpmux::protocol::registry`.

import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { generate } from "../src/protocol/codegen/acpmux";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(webviewsRoot, "..");
const outRel = "src/agent-session/acpmux/protocol/generated";
const outDir = path.join(webviewsRoot, outRel);

const args = process.argv.slice(2);
const check = args.includes("--check");
const irIndex = args.indexOf("--ir");
if (irIndex !== -1 && !args[irIndex + 1]) {
  console.error("--ir needs a path");
  process.exit(2);
}
const irPath = path.resolve(
  irIndex === -1 ? path.join(repoRoot, "cmux-tui/crates/acpmux/spec/acpmux-protocol.json") : args[irIndex + 1],
);
const source = path.relative(repoRoot, irPath).split(path.sep).join("/");

if (!existsSync(irPath)) {
  console.error(`acpmux protocol IR not found: ${source}`);
  console.error("it is written by the acpmux Rust test that emits the protocol IR; regenerate it there first");
  process.exit(1);
}

const files = generate(JSON.parse(readFileSync(irPath, "utf8")), { source });

if (check) {
  const drift: string[] = [];
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(outDir, name);
    if (!existsSync(file) || readFileSync(file, "utf8") !== content) drift.push(name);
  }
  const extra = existsSync(outDir) ? readdirSync(outDir).filter((name) => !(name in files)) : [];
  if (drift.length > 0 || extra.length > 0) {
    console.error(`acpmux protocol generated files are stale in ${outRel}: ${[...drift, ...extra].join(", ")}`);
    console.error(
      "rerun from webviews/: ACPMUX_PROTOCOL_BLESS=1 cargo test --manifest-path ../cmux-tui/Cargo.toml -p acpmux protocol_ir_is_current && bun scripts/acpmux-protocol-codegen.ts",
    );
    process.exit(1);
  }
  console.log(`acpmux protocol generated code is current (${source})`);
} else {
  mkdirSync(outDir, { recursive: true });
  for (const [name, content] of Object.entries(files)) writeFileSync(path.join(outDir, name), content);
  console.log(`wrote ${Object.keys(files).length} files to ${outRel} from ${source}`);
}
