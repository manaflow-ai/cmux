#!/usr/bin/env bun

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const COMPLEXITY_CODE = "eslint(complexity)";
const BASELINE_FILE = "web/oxlint-complexity-baseline.txt";
const SOURCE_EXTENSIONS = /\.(?:js|jsx|mjs|cjs|ts|tsx|mts|cts)$/;
const EXCLUDED_PREFIXES = [
  ".next/",
  "coverage/",
  "db/migrations/",
  "e2e/",
  "node_modules/",
  "out/",
  "public/",
  "scripts/",
  "tests/",
  "tools/",
];

function fail(message) {
  console.error(`complexity gate: ${message}`);
  process.exit(2);
}

function git(args, cwd = process.cwd(), allowFailure = false) {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 && !allowFailure) {
    const detail = (result.stderr || result.stdout || "").trim();
    fail(`git ${args.join(" ")} failed${detail ? `: ${detail}` : ""}`);
  }
  return result;
}

function parseArgs() {
  let base;
  let head;
  const files = [];
  const args = process.argv.slice(2);

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--help" || arg === "-h") {
      console.log("Usage: bun scripts/check-complexity.mjs [--base <sha> --head <sha>] [--files <path> ...]");
      process.exit(0);
    }
    if (arg === "--base" || arg === "--head") {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) fail(`${arg} requires a commit SHA`);
      if (arg === "--base") base = value;
      else head = value;
      index += 1;
      continue;
    }
    if (arg === "--files") {
      if (index + 1 >= args.length) fail("--files requires at least one path");
      files.push(...args.slice(index + 1));
      break;
    }
    fail(`unknown argument ${arg}`);
  }

  if ((base && !head) || (!base && head)) fail("--base and --head must be provided together");
  return { base, head, files };
}

function isProductionSource(repoPath) {
  if (!repoPath.startsWith("web/")) return false;
  const webPath = repoPath.slice("web/".length);
  return SOURCE_EXTENSIONS.test(webPath) && !EXCLUDED_PREFIXES.some((prefix) => webPath.startsWith(prefix));
}

function normalizeWebPath(repoRoot, input) {
  const webRoot = path.join(repoRoot, "web");
  const absolute = path.isAbsolute(input)
    ? path.normalize(input)
    : input === "web" || input.startsWith("web/")
      ? path.resolve(repoRoot, input)
      : path.resolve(webRoot, input);
  const relative = path.relative(webRoot, absolute).split(path.sep).join("/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    fail(`path is outside web/: ${input}`);
  }
  return `web/${relative}`;
}

function sourceFiles(repoRoot, explicitFiles) {
  if (explicitFiles.length > 0) {
    return [...new Set(explicitFiles.map((file) => normalizeWebPath(repoRoot, file)).filter(isProductionSource))]
      .map((file) => file.slice("web/".length))
      .filter((file) => existsSync(path.join(repoRoot, "web", file)))
      .sort();
  }

  const tracked = git(["ls-files", "--", "web"], repoRoot).stdout;
  const untracked = git(["ls-files", "--others", "--exclude-standard", "--", "web"], repoRoot).stdout;
  return [...new Set(`${tracked}\n${untracked}`.split("\n").filter(Boolean))]
    .filter(isProductionSource)
    .map((file) => file.slice("web/".length))
    .sort();
}

function baselineEntries(text) {
  return new Set(
    text
      .split("\n")
      .map((line) => line.trimEnd())
      .filter((line) => line && !line.startsWith("#")),
  );
}

function readBaseline(repoRoot) {
  const file = path.join(repoRoot, BASELINE_FILE);
  return existsSync(file) ? baselineEntries(readFileSync(file, "utf8")) : new Set();
}

function baselineAt(repoRoot, revision) {
  const result = git(["show", `${revision}:${BASELINE_FILE}`], repoRoot, true);
  return result.status === 0 ? baselineEntries(result.stdout) : new Set();
}

function assertBaselineOnlyShrinks(repoRoot, base, baseline) {
  if (!base) return;
  const previous = baselineAt(repoRoot, base);
  if (previous.size === 0) return;
  const additions = [...baseline].filter((entry) => !previous.has(entry)).sort();
  if (additions.length === 0) return;
  console.error("complexity gate: the baseline may only shrink; fix the finding instead of adding it:");
  for (const entry of additions) console.error(`  ${entry}`);
  process.exit(1);
}

function assertCheckedOutHead(repoRoot, head) {
  if (!head) return;
  const expected = git(["rev-parse", head], repoRoot).stdout.trim();
  const actual = git(["rev-parse", "HEAD"], repoRoot).stdout.trim();
  if (expected !== actual) {
    fail(`checked out commit ${actual} does not match requested head ${expected}`);
  }
}

function configuredComplexityLimit(repoRoot) {
  const config = JSON.parse(readFileSync(path.join(repoRoot, "web", ".oxlintrc.json"), "utf8"));
  const rule = config.rules?.complexity;
  const options = Array.isArray(rule) ? rule[1] : undefined;
  const limit = options?.max;
  if (typeof limit !== "number" || !Number.isFinite(limit)) {
    fail(".oxlintrc.json must set a numeric complexity max");
  }
  return limit;
}

function runOxlint(repoRoot, files) {
  const webRoot = path.join(repoRoot, "web");
  const result = spawnSync(
    path.join(webRoot, "node_modules", ".bin", "oxlint"),
    [
      "--config",
      ".oxlintrc.json",
      "-A",
      "all",
      "-D",
      "complexity",
      "--format",
      "json",
      "--no-error-on-unmatched-pattern",
      ...files,
    ],
    { cwd: webRoot, encoding: "utf8", maxBuffer: 20 * 1024 * 1024 },
  );
  if (result.error) fail(`could not start oxlint: ${result.error.message}`);

  let report;
  try {
    report = JSON.parse(result.stdout || "{}");
  } catch {
    fail(`oxlint returned invalid JSON${result.stderr ? `: ${result.stderr.trim()}` : ""}`);
  }
  const diagnostics = Array.isArray(report.diagnostics) ? report.diagnostics : [];
  if (result.status !== 0 && diagnostics.length === 0) {
    fail(`oxlint failed${result.stderr ? `: ${result.stderr.trim()}` : ""}`);
  }
  return { diagnostics, stderr: result.stderr || "", status: result.status ?? 1 };
}

function diagnosticKey(diagnostic) {
  const filename = String(diagnostic.filename ?? "").replace(/^\.\//, "");
  return `${filename}\t${String(diagnostic.message ?? "")}`;
}

const { base, head, files: explicitFiles } = parseArgs();
const repoRoot = git(["rev-parse", "--show-toplevel"]).stdout.trim();
assertCheckedOutHead(repoRoot, head);
const baseline = readBaseline(repoRoot);
assertBaselineOnlyShrinks(repoRoot, base, baseline);
const files = sourceFiles(repoRoot, explicitFiles);
if (files.length === 0) {
  console.log("complexity gate: no production web files to scan");
  process.exit(0);
}

const complexityLimit = configuredComplexityLimit(repoRoot);
const { diagnostics, stderr, status } = runOxlint(repoRoot, files);
const unexpected = diagnostics.filter((diagnostic) => diagnostic.code !== COMPLEXITY_CODE);
if (unexpected.length > 0 || (status !== 0 && diagnostics.length === 0)) {
  for (const diagnostic of unexpected) console.error(`${diagnostic.filename}: ${diagnostic.message}`);
  if (stderr.trim()) console.error(stderr.trim());
  process.exit(1);
}

const newFindings = diagnostics.filter((diagnostic) => !baseline.has(diagnosticKey(diagnostic)));
if (newFindings.length === 0) {
  const currentKeys = new Set(diagnostics.map(diagnosticKey));
  const stale = [...baseline].filter((entry) => !currentKeys.has(entry));
  console.log(
    `complexity gate: ${diagnostics.length} finding${diagnostics.length === 1 ? "" : "s"} matched the grandfathered baseline` +
      (stale.length > 0 ? `; ${stale.length} stale entr${stale.length === 1 ? "y" : "ies"} can be removed` : ""),
  );
  process.exit(0);
}

console.error(`complexity gate: ${newFindings.length} new finding${newFindings.length === 1 ? "" : "s"} exceed complexity ${complexityLimit}`);
for (const diagnostic of newFindings) {
  const filename = String(diagnostic.filename ?? "").replace(/^\.\//, "");
  const line = diagnostic.labels?.[0]?.span?.line ?? 1;
  const message = String(diagnostic.message ?? "complexity exceeds the configured limit").replace(/\r?\n/g, " ");
  console.error(`::error file=web/${filename},line=${line},title=Oxlint complexity::${message}`);
}
process.exit(1);
