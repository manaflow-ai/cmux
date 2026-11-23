#!/usr/bin/env bun
// Generates webviews/src/agent-session/acpmux/protocol/generated/ from the acpmux protocol IR.
//
//   bun scripts/acpmux-protocol-codegen.ts            # write
//   bun scripts/acpmux-protocol-codegen.ts --ir <path>
//
// The output is build output, not in git (gitignored): bun install's postinstall, the webviews
// test preload and every gen-strings.mjs run (the bundle builds) write it, and `bun run typecheck`,
// `dev*` and `preview:*` run this first. A file is written only when its content changed, so
// watchers and incremental type checks see no churn.
//
// The default IR is the daemon's committed emit (`cmux-tui/crates/acpmux/spec/acpmux-protocol.json`),
// which a Rust test keeps in step with `acpmux::protocol::registry`.

import { mkdirSync, readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { generate } from "../src/protocol/codegen/acpmux";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(webviewsRoot, "..");
const outRel = "src/agent-session/acpmux/protocol/generated";
const outDir = path.join(webviewsRoot, outRel);
const defaultIr = path.join(repoRoot, "cmux-tui/crates/acpmux/spec/acpmux-protocol.json");

/** Writes the generated files that differ from what IR_PATH generates; returns how many it wrote. */
export function writeAcpmuxProtocol({ irPath = defaultIr, log = console.log } = {}): number {
  const source = path.relative(repoRoot, irPath).split(path.sep).join("/");
  if (!existsSync(irPath)) {
    throw new Error(
      `acpmux protocol IR not found: ${source}; it is written by the acpmux Rust test that emits the protocol IR`,
    );
  }
  const files = generate(JSON.parse(readFileSync(irPath, "utf8")), { source });
  let wrote = 0;
  mkdirSync(outDir, { recursive: true });
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(outDir, name);
    if (existsSync(file) && readFileSync(file, "utf8") === content) continue;
    // Written then renamed: test processes run the preload in parallel.
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, content);
    renameSync(temp, file);
    wrote += 1;
  }
  log(`acpmux protocol: ${wrote} of ${Object.keys(files).length} files written to ${outRel} from ${source}`);
  return wrote;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const irIndex = args.indexOf("--ir");
  if (irIndex !== -1 && !args[irIndex + 1]) {
    console.error("--ir needs a path");
    process.exit(2);
  }
  try {
    writeAcpmuxProtocol({ irPath: irIndex === -1 ? defaultIr : path.resolve(args[irIndex + 1]) });
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
