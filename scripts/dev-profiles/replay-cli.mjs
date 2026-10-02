#!/usr/bin/env node
// CLI wrapper around the dev-profile replay engine.
//
// Usage:
//   replay-cli.mjs --tag <tag> --profile <name[,name2,...]> [--cwd <dir>] [--dry-run]
//   replay-cli.mjs --list
//
// `dev-setup.sh --profile <name>` calls this after the app is built/launched/
// paired. Everything routes through `scripts/cmux-debug-cli.sh` (sibling
// `../cmux-debug-cli.sh`), which targets the TAGGED socket only.
//
// --dry-run prints the resolved `cmux` argument vectors for each profile
// without touching a socket. It is the same construction path the unit test
// exercises, so a green dry run proves the parsing + substitution plumbing.

import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  listProfiles,
  loadProfile,
  ProfileReplayer,
  resolveSteps,
} from "./replay.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEBUG_CLI = path.join(SCRIPT_DIR, "..", "cmux-debug-cli.sh");

function parseArgs(argv) {
  const opts = { tag: "", profiles: [], cwd: process.cwd(), dryRun: false, list: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    switch (a) {
      case "--tag":
        opts.tag = argv[(i += 1)] ?? "";
        break;
      case "--profile":
        opts.profiles.push(
          ...(argv[(i += 1)] ?? "")
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean),
        );
        break;
      case "--cwd":
        opts.cwd = argv[(i += 1)] ?? process.cwd();
        break;
      case "--dry-run":
        opts.dryRun = true;
        break;
      case "--list":
        opts.list = true;
        break;
      default:
        throw new Error(`unknown arg: ${a}`);
    }
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.list) {
    for (const name of listProfiles(SCRIPT_DIR)) {
      process.stdout.write(`${name}\n`);
    }
    return;
  }

  if (opts.profiles.length === 0) {
    throw new Error("at least one --profile <name> is required");
  }
  // Validate every requested profile up front so an unknown name fails before
  // any side effects, listing the available profiles.
  const profiles = opts.profiles.map((name) => ({
    name,
    profile: loadProfile(SCRIPT_DIR, name),
  }));

  const context = { cwd: opts.cwd };

  if (opts.dryRun) {
    for (const { name, profile } of profiles) {
      process.stdout.write(`# profile: ${name}\n`);
      for (const { argv } of resolveSteps(profile, context)) {
        process.stdout.write(`cmux ${argv.join(" ")}\n`);
      }
    }
    return;
  }

  if (!opts.tag) {
    throw new Error("--tag is required to replay a profile (omit for --dry-run)");
  }

  for (const { name, profile } of profiles) {
    process.stderr.write(`==> applying profile "${name}" against tag "${opts.tag}"\n`);
    const replayer = new ProfileReplayer({
      tag: opts.tag,
      cliPath: DEBUG_CLI,
      context,
      log: (m) => process.stderr.write(`${m}\n`),
    });
    replayer.run(profile);
  }
  process.stderr.write(`==> profiles applied: ${opts.profiles.join(", ")}\n`);
}

try {
  main();
} catch (err) {
  process.stderr.write(`dev-profile replay error: ${err.message}\n`);
  process.exit(1);
}
