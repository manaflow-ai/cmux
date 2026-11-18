#!/usr/bin/env node
// Adds a pull request's new migration folders to a checkout of main, so an
// operator can apply them to staging and production before the merge that
// deploys their readers. Only migration files move: the migrator, its
// connection policy and the workflow stay main's trusted code.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { planMigrationOverlay } from "./migration-ledger.mjs";

const MIGRATIONS = "web/db/migrations";
const usage = "Usage: stage-migration-source.mjs --repo <dir> --base <commit> --source <commit>";

function parseArgs(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!["--repo", "--base", "--source"].includes(flag) || !value) {
      console.error(usage);
      process.exit(2);
    }
    options[flag.slice(2)] = value;
  }
  if (!options.repo || !options.base || !options.source) {
    console.error(usage);
    process.exit(2);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const git = (...args) => execFileSync("git", ["-C", options.repo, ...args], { maxBuffer: 64 * 1024 * 1024 });
const text = (...args) => git(...args).toString("utf8").trim();

function migrationTree(commit) {
  const folders = new Map();
  for (const line of text("ls-tree", "-r", "--full-tree", commit, "--", `${MIGRATIONS}/`).split("\n")) {
    if (!line) continue;
    const [meta, filePath] = line.split("\t");
    const [, type, blob] = meta.split(" ");
    const relative = filePath.slice(MIGRATIONS.length + 1).split("/");
    if (type !== "blob" || relative.length !== 2) continue;
    const [folder, file] = relative;
    if (!folders.has(folder)) folders.set(folder, new Map());
    folders.get(folder).set(file, blob);
  }
  return folders;
}

const base = text("rev-parse", "--verify", `${options.base}^{commit}`);
const source = text("rev-parse", "--verify", `${options.source}^{commit}`);
const head = text("rev-parse", "HEAD");
if (head !== base) {
  console.error(`The checkout is at ${head}, not the base ${base}; refusing to mix trees.`);
  process.exit(1);
}

const baseTree = migrationTree(base);
const sourceTree = migrationTree(source);
const plan = planMigrationOverlay({ base: baseTree, source: sourceTree });
if (plan.conflicts.length > 0) {
  console.error(
    `${source} edits ${plan.conflicts.length === 1 ? "a migration" : "migrations"} already on main: ${plan.conflicts.join(", ")}.\n` +
    "Drizzle skips an applied name, so the edit would never run. Put the change in a new migration folder.",
  );
  process.exit(1);
}

const root = path.join(options.repo, MIGRATIONS);
for (const folder of plan.add) {
  for (const [file, blob] of sourceTree.get(folder)) {
    mkdirSync(path.join(root, folder), { recursive: true });
    writeFileSync(path.join(root, folder, file), git("cat-file", "blob", blob));
  }
}
console.log(plan.add.length === 0
  ? `${source} adds no migrations beyond main.`
  : `Staged ${plan.add.length} migration${plan.add.length === 1 ? "" : "s"} from ${source}:\n${plan.add.map((name) => `  - ${name}`).join("\n")}`);
