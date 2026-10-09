#!/usr/bin/env node
// The one Freestyle dev key (Lawrence, 2026-10-09: one dev key; the per-env
// key files under ~/.secrets are retired). It is FREESTYLE_API_KEY in
// ~/.secrets/cmux.env, the file the dev backend also installs; set
// CMUX_FREESTYLE_DEV_ENV_FILE to read another env file.
//
// Library:  import { freestyleDevKey } from "<repo>/scripts/lib/freestyle-dev-key.mjs";
// Pipe:     node scripts/lib/freestyle-dev-key.mjs | ssh host 'cat > ~/.key'
//
// Only that one line is read; no other line of the env file leaves this
// module. The CLI writes the key, without a newline, to stdout only when
// stdout is not a terminal, and errors never contain file content.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const LINE = /^\s*(?:export\s+)?FREESTYLE_API_KEY\s*=(.*)$/;

/** The env file that holds the dev key. */
export function devKeyEnvFile(env = process.env) {
  const override = env.CMUX_FREESTYLE_DEV_ENV_FILE?.trim();
  if (override) return override;
  return join(env.HOME?.trim() || homedir(), ".secrets", "cmux.env");
}

/** FREESTYLE_API_KEY from env file text; the last assignment wins, as in a shell. */
export function parseFreestyleApiKey(text) {
  let value;
  for (const line of text.split(/\r?\n/)) {
    const match = LINE.exec(line);
    if (match) value = match[1].trim();
  }
  if (value === undefined) throw new Error("the env file has no FREESTYLE_API_KEY line");
  const quoted = /^(["'])(.*)\1$/.exec(value);
  const key = (quoted ? quoted[2] : value).trim();
  if (key === "") throw new Error("FREESTYLE_API_KEY is empty in the env file");
  return key;
}

/** The Freestyle dev key, read from `file` (default: devKeyEnvFile()). */
export function freestyleDevKey({ file = devKeyEnvFile() } = {}) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    throw new Error(`cannot read the Freestyle dev key file ${file}`);
  }
  try {
    return parseFreestyleApiKey(text);
  } catch (error) {
    throw new Error(`${error.message} (${file})`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  if (process.stdout.isTTY) {
    console.error("freestyle-dev-key: refusing to print the key to a terminal; pipe it into the command that needs it");
    process.exit(2);
  }
  try {
    process.stdout.write(freestyleDevKey());
  } catch (error) {
    console.error(`freestyle-dev-key: ${error.message}`);
    process.exit(1);
  }
}
