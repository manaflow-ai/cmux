#!/usr/bin/env bun

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import * as ts from "typescript";

const COMPLEXITY_CODE = "eslint(complexity)";
const COMPLEXITY_LIMIT = 20;
const COMPLEXITY_VARIANT = "classic";
const BASELINE_FILE = "web/oxlint-complexity-baseline.txt";
const SOURCE_EXTENSIONS = /\.(?:js|jsx|mjs|cjs|ts|tsx|mts|cts)$/;
const FINGERPRINT_LENGTH = 64;
const FINGERPRINT_PATTERN = new RegExp(`^[0-9a-f]{${FINGERPRINT_LENGTH}}$`);
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
const TRUSTED_POLICY_FILES = ["web/scripts/check-complexity.mjs", ".github/workflows/web-complexity-trusted.yml"];

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
  let repoRoot;
  let toolRoot;
  let baseBaseline;
  const files = [];
  const args = process.argv.slice(2);

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--help" || arg === "-h") {
      console.log(
        "Usage: bun scripts/check-complexity.mjs [--base <sha> --head <sha>] [--repo-root <path>] [--tool-root <path>] [--base-baseline <path>] [--files <path> ...]",
      );
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
    if (arg === "--repo-root" || arg === "--tool-root" || arg === "--base-baseline") {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) fail(`${arg} requires a path`);
      if (arg === "--repo-root") repoRoot = value;
      else if (arg === "--tool-root") toolRoot = value;
      else baseBaseline = value;
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

  if ((base && !head) || (!base && head && !baseBaseline)) fail("--base or --base-baseline must be provided with --head");
  if (base && baseBaseline) fail("use only one of --base and --base-baseline");
  return { base, head, repoRoot, toolRoot, baseBaseline, files };
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

function scriptKindFor(filename) {
  if (/\.tsx?$/.test(filename)) return ts.ScriptKind.TSX;
  if (/\.jsx?$/.test(filename)) return ts.ScriptKind.JSX;
  return ts.ScriptKind.JS;
}

function normalizedSyntax(text) {
  return text.replace(/\s+/g, " ").trim();
}

function byteOffsetToCharacterOffset(source, byteOffset) {
  if (!Number.isInteger(byteOffset) || byteOffset < 0) return -1;
  let low = 0;
  let high = source.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (Buffer.byteLength(source.slice(0, middle), "utf8") < byteOffset) low = middle + 1;
    else high = middle;
  }
  return low;
}

function diagnosticFilename(repoRoot, diagnostic) {
  const raw = String(diagnostic.filename ?? "").replace(/^\.\//, "");
  const webRoot = path.join(repoRoot, "web");
  const candidate = raw.startsWith("web/") ? raw.slice("web/".length) : raw;
  const absolute = path.isAbsolute(raw) ? path.normalize(raw) : path.resolve(webRoot, candidate);
  const relative = path.relative(webRoot, absolute).split(path.sep).join("/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    fail(`oxlint reported a file outside web/: ${raw}`);
  }
  return relative;
}

function containsNode(parent, child) {
  return child.pos >= parent.pos && child.end <= parent.end;
}

function nodeName(node, sourceFile) {
  return node.name ? normalizedSyntax(node.name.getText(sourceFile)) : "";
}

function functionHeader(node, sourceFile) {
  const bodyStart = node.body?.getStart(sourceFile) ?? node.end;
  return normalizedSyntax(sourceFile.text.slice(node.getStart(sourceFile), bodyStart));
}

function functionNodeAt(sourceFile, characterOffset) {
  let match;
  function visit(node) {
    if (
      ts.isFunctionLike(node) &&
      node.body &&
      characterOffset >= node.getStart(sourceFile) &&
      characterOffset < node.end &&
      (!match || node.end - node.getStart(sourceFile) < match.end - match.getStart(sourceFile))
    ) {
      match = node;
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return match;
}

function functionBodyAnchor(node, sourceFile) {
  if (!node.body) return "";
  if (ts.isBlock(node.body)) {
    const firstStatement = node.body.statements[0];
    return firstStatement ? normalizedSyntax(firstStatement.getText(sourceFile)).slice(0, 200) : "<empty>";
  }
  return normalizedSyntax(node.body.getText(sourceFile)).slice(0, 200);
}

function directChild(parent, target) {
  let child = target;
  while (child.parent && child.parent !== parent) child = child.parent;
  return child;
}

function containsFunctionBody(node) {
  let found = false;
  function visit(child) {
    if (ts.isFunctionLike(child) && child.body) {
      found = true;
      return;
    }
    ts.forEachChild(child, visit);
  }
  visit(node);
  return found;
}

function functionSignature(node, sourceFile) {
  return `${ts.SyntaxKind[node.kind]}:${nodeName(node, sourceFile)}:${functionHeader(node, sourceFile)}`;
}

function childFunctionSignature(node, sourceFile) {
  const signatures = [];
  function visit(child) {
    if (ts.isFunctionLike(child) && child.body) {
      signatures.push(functionSignature(child, sourceFile));
      return;
    }
    ts.forEachChild(child, visit);
  }
  visit(node);
  return signatures.join("|");
}

function siblingOrdinal(parent, child, sourceFile) {
  const targetChild = directChild(parent, child);
  const targetSignature = childFunctionSignature(targetChild, sourceFile);
  const siblings = parent.getChildren(sourceFile).filter(containsFunctionBody);
  const matchingSiblings = siblings.filter((sibling) => childFunctionSignature(sibling, sourceFile) === targetSignature);
  return matchingSiblings.indexOf(targetChild);
}

function contextDescriptor(node, sourceFile) {
  if (ts.isIfStatement(node)) return `if:${normalizedSyntax(node.expression.getText(sourceFile))}`;
  if (ts.isIterationStatement(node)) return `loop:${normalizedSyntax(node.expression?.getText(sourceFile) ?? "")}`;
  if (ts.isSwitchStatement(node)) return `switch:${normalizedSyntax(node.expression.getText(sourceFile))}`;
  if (ts.isCaseClause(node)) return `case:${normalizedSyntax(node.expression.getText(sourceFile))}`;
  if (ts.isCatchClause(node)) return `catch:${normalizedSyntax(node.variableDeclaration?.getText(sourceFile) ?? "")}`;
  if (ts.isObjectLiteralExpression(node)) {
    return `object:${node.properties.map((property) => normalizedSyntax(property.name?.getText(sourceFile) ?? "")).join(",")}`;
  }
  if (ts.isArrayLiteralExpression(node)) return `array:${node.elements.length}`;
  if (ts.isTryStatement(node)) return "try";
  if (ts.isBlock(node)) return "block";
  return undefined;
}

function functionIdentity(sourceFile, node) {
  const parts = [`self:${nodeName(node, sourceFile) || "anonymous"}`, `header:${functionHeader(node, sourceFile)}`];
  if (!nodeName(node, sourceFile)) parts.push(`body:${functionBodyAnchor(node, sourceFile)}`);
  let child = node;
  for (let parent = node.parent; parent && !ts.isSourceFile(parent); parent = parent.parent) {
    if (ts.isCallExpression(parent)) {
      const argumentIndex = parent.arguments.findIndex((argument) => containsNode(argument, child));
      parts.push(`call:${normalizedSyntax(parent.expression.getText(sourceFile))}#${argumentIndex}`);
    } else if (ts.isVariableDeclaration(parent) && parent.initializer && containsNode(parent.initializer, child)) {
      parts.push(`var:${nodeName(parent, sourceFile)}`);
    } else if (
      (ts.isPropertyAssignment(parent) || ts.isPropertyDeclaration(parent)) &&
      parent.initializer &&
      containsNode(parent.initializer, child)
    ) {
      parts.push(`prop:${nodeName(parent, sourceFile)}`);
    } else if (ts.isClassDeclaration(parent) && parent.name) {
      parts.push(`class:${nodeName(parent, sourceFile)}`);
    } else if (ts.isFunctionLike(parent)) {
      parts.push(`parent:${nodeName(parent, sourceFile) || functionHeader(parent, sourceFile)}`);
    } else if (ts.isPropertyAccessExpression(parent)) {
      parts.push(`access:${normalizedSyntax(parent.name.getText(sourceFile))}`);
    } else if (ts.isElementAccessExpression(parent) && parent.argumentExpression) {
      parts.push(`element:${normalizedSyntax(parent.argumentExpression.getText(sourceFile))}`);
    }
    const context = contextDescriptor(parent, sourceFile);
    if (context) {
      parts.push(`context:${context}`);
      parts.push(`sibling:${siblingOrdinal(parent, child, sourceFile)}`);
    }
    child = parent;
  }
  return parts.reverse().join("/");
}

const sourceFileCache = new Map();

function sourceFileFor(repoRoot, filename) {
  const cached = sourceFileCache.get(filename);
  if (cached) return cached;
  const source = readFileSync(path.join(repoRoot, "web", filename), "utf8");
  const sourceFile = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, scriptKindFor(filename));
  sourceFileCache.set(filename, sourceFile);
  return sourceFile;
}

function diagnosticFingerprint(repoRoot, diagnostic) {
  const filename = diagnosticFilename(repoRoot, diagnostic);
  const sourceFile = sourceFileFor(repoRoot, filename);
  const spanOffset = diagnostic.labels?.[0]?.span?.offset;
  const characterOffset = byteOffsetToCharacterOffset(sourceFile.text, spanOffset);
  const node = functionNodeAt(sourceFile, characterOffset);
  if (!node) fail(`could not identify the function for ${filename} at byte offset ${spanOffset}`);
  return createHash("sha256").update(functionIdentity(sourceFile, node)).digest("hex");
}

function baselineEntries(text) {
  const entries = new Map();
  for (const line of text.split("\n").map((line) => line.trimEnd())) {
    if (!line || line.startsWith("#")) continue;
    const fields = line.split("\t");
    if (fields.length < 3 || !fields[0] || !FINGERPRINT_PATTERN.test(fields[1])) {
      fail(`invalid baseline entry (expected path, fingerprint, message): ${line}`);
    }
    const key = `${fields[0]}\t${fields[1]}\t${fields.slice(2).join("\t")}`;
    entries.set(key, (entries.get(key) ?? 0) + 1);
  }
  return entries;
}

function baselineEntryPath(entry) {
  return entry.slice(0, entry.indexOf("\t"));
}

function readBaseline(repoRoot) {
  const file = path.join(repoRoot, BASELINE_FILE);
  if (!existsSync(file)) fail(`${BASELINE_FILE} is required; restore it instead of disabling the gate`);
  return baselineEntries(readFileSync(file, "utf8"));
}

function readJson(file, label) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function complexityRule(configRoot) {
  const config = readJson(path.join(configRoot, "web", ".oxlintrc.json"), ".oxlintrc.json");
  const rule = config.rules?.complexity;
  const options = Array.isArray(rule) ? rule[1] : undefined;
  if (options?.max !== COMPLEXITY_LIMIT || options?.variant !== COMPLEXITY_VARIANT) {
    fail(`.oxlintrc.json must keep complexity max ${COMPLEXITY_LIMIT} with the ${COMPLEXITY_VARIANT} variant`);
  }
  return COMPLEXITY_LIMIT;
}

function oxlintLockEntries(root) {
  const lockfile = path.join(root, "web", "bun.lock");
  if (!existsSync(lockfile)) fail("web/bun.lock is required for the pinned Oxlint toolchain");
  return readFileSync(lockfile, "utf8")
    .split("\n")
    .filter((line) => line.includes("oxlint"))
    .join("\n");
}

function assertTrustedPolicy(repoRoot, toolRoot) {
  if (path.resolve(repoRoot) === path.resolve(toolRoot)) return;

  for (const relative of TRUSTED_POLICY_FILES) {
    const trustedFile = path.join(toolRoot, relative);
    const candidateFile = path.join(repoRoot, relative);
    if (!existsSync(trustedFile) || !existsSync(candidateFile)) {
      fail(`${relative} must remain present and unchanged in a pull request`);
    }
    if (readFileSync(trustedFile).compare(readFileSync(candidateFile)) !== 0) {
      fail(`${relative} is a trusted policy file and must be changed in a separate reviewed update`);
    }
  }

  complexityRule(repoRoot);
  const trustedPackage = readJson(path.join(toolRoot, "web", "package.json"), "trusted web/package.json");
  const candidatePackage = readJson(path.join(repoRoot, "web", "package.json"), "web/package.json");
  if (candidatePackage.devDependencies?.oxlint !== trustedPackage.devDependencies?.oxlint) {
    fail("the pinned Oxlint dependency may not change in a normal pull request");
  }
  if (oxlintLockEntries(repoRoot) !== oxlintLockEntries(toolRoot)) {
    fail("the pinned Oxlint lock entries may not change in a normal pull request");
  }
}

function baselineAt(repoRoot, revision, baseBaseline) {
  if (baseBaseline) {
    if (!existsSync(baseBaseline)) fail(`base baseline ${baseBaseline} is not available`);
    return { exists: true, entries: baselineEntries(readFileSync(baseBaseline, "utf8")) };
  }
  if (!revision) return { exists: false, entries: new Map() };
  const commit = git(["rev-parse", "--verify", `${revision}^{commit}`], repoRoot, true);
  if (commit.status !== 0) fail(`base revision ${revision} is not available in the checkout`);

  const baselineObject = git(["cat-file", "-e", `${revision}:${BASELINE_FILE}`], repoRoot, true);
  if (baselineObject.status !== 0) return { exists: false, entries: new Map() };

  const result = git(["show", `${revision}:${BASELINE_FILE}`], repoRoot, true);
  if (result.status !== 0) fail(`could not read ${BASELINE_FILE} at base revision ${revision}`);
  return { exists: true, entries: baselineEntries(result.stdout) };
}

function assertBaselineOnlyShrinks(repoRoot, base, baseline, baseBaseline) {
  if (!base && !baseBaseline) return;
  const previous = baselineAt(repoRoot, base, baseBaseline);
  if (!previous.exists) return;
  const additions = [];
  for (const [entry, count] of baseline) {
    const previousCount = previous.entries.get(entry) ?? 0;
    for (let index = previousCount; index < count; index += 1) additions.push(entry);
  }
  additions.sort();
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

function configuredComplexityLimit(toolRoot) {
  return complexityRule(toolRoot);
}

function runOxlint(repoRoot, toolRoot, files) {
  const webRoot = path.join(repoRoot, "web");
  const toolWebRoot = path.join(toolRoot, "web");
  const result = spawnSync(
    path.join(toolWebRoot, "node_modules", ".bin", "oxlint"),
    [
      "--config",
      path.join(toolWebRoot, ".oxlintrc.json"),
      "--no-ignore",
      "--disable-nested-config",
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
  return {
    diagnostics,
    stderr: result.stderr || "",
    status: result.status ?? 1,
  };
}

function broadComplexitySuppression(comment) {
  const body = comment.replace(/^\/\//, "").replace(/^\/\*/, "").replace(/\*\/$/, "").trim().replace(/\s+/g, " ");
  const match = body.match(/^(?:oxlint|eslint)-disable(?:-(file|next-line|line))?(?:\s+([\s\S]*))?$/);
  if (!match) return false;
  const suffix = match[1];
  if (suffix === "next-line" || suffix === "line") return false;
  const rulesText = (match[2] ?? "").split("--", 1)[0].trim();
  if (suffix === "file") return true;
  if (!rulesText) return true;
  return rulesText.split(/[\s,]+/).some((rule) => rule === "complexity" || rule.endsWith("/complexity") || rule.endsWith("(complexity)"));
}

function assertNoBroadComplexitySuppressions(repoRoot, files) {
  const violations = [];
  for (const filename of files) {
    const source = readFileSync(path.join(repoRoot, "web", filename), "utf8");
    const sourceFile = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, scriptKindFor(filename));
    const scanner = ts.createScanner(
      ts.ScriptTarget.Latest,
      false,
      /\.tsx?$/.test(filename) || /\.jsx?$/.test(filename) ? ts.LanguageVariant.JSX : ts.LanguageVariant.Standard,
      source,
    );
    let token;
    while ((token = scanner.scan()) !== ts.SyntaxKind.EndOfFileToken) {
      if (token !== ts.SyntaxKind.SingleLineCommentTrivia && token !== ts.SyntaxKind.MultiLineCommentTrivia) continue;
      const comment = scanner.getTokenText();
      if (!broadComplexitySuppression(comment)) continue;
      const position = scanner.getTokenPos();
      const line = ts.getLineAndCharacterOfPosition(sourceFile, position).line + 1;
      violations.push(`web/${filename}:${line}`);
    }
  }
  if (violations.length === 0) return;
  console.error("complexity gate: broad complexity suppressions are not allowed; use a narrow line suppression with a reason:");
  for (const violation of violations) console.error(`  ${violation}`);
  process.exit(1);
}

function diagnosticKey(repoRoot, diagnostic) {
  const filename = diagnosticFilename(repoRoot, diagnostic);
  return `${filename}\t${diagnosticFingerprint(repoRoot, diagnostic)}\t${String(diagnostic.message ?? "")}`;
}

const { base, head, repoRoot: requestedRepoRoot, toolRoot: requestedToolRoot, baseBaseline, files: explicitFiles } = parseArgs();
const repoRoot = requestedRepoRoot ? path.resolve(requestedRepoRoot) : git(["rev-parse", "--show-toplevel"]).stdout.trim();
const toolRoot = requestedToolRoot ? path.resolve(requestedToolRoot) : repoRoot;
assertCheckedOutHead(repoRoot, head);
assertTrustedPolicy(repoRoot, toolRoot);
const baseline = readBaseline(repoRoot);
assertBaselineOnlyShrinks(repoRoot, base, baseline, baseBaseline ? path.resolve(baseBaseline) : undefined);
const files = sourceFiles(repoRoot, explicitFiles);
const scannedFiles = explicitFiles.length > 0 ? new Set(files) : undefined;
if (files.length === 0) {
  if (explicitFiles.length === 0 && baseline.size > 0) {
    fail("the baseline still contains findings but no production web files are available to scan");
  }
  console.log("complexity gate: no production web files to scan");
  process.exit(0);
}

const complexityLimit = configuredComplexityLimit(toolRoot);
assertNoBroadComplexitySuppressions(repoRoot, files);
const { diagnostics, stderr, status } = runOxlint(repoRoot, toolRoot, files);
const unexpected = diagnostics.filter((diagnostic) => diagnostic.code !== COMPLEXITY_CODE);
if (unexpected.length > 0 || (status !== 0 && diagnostics.length === 0)) {
  for (const diagnostic of unexpected) console.error(`${diagnostic.filename}: ${diagnostic.message}`);
  if (stderr.trim()) console.error(stderr.trim());
  process.exit(1);
}

const matchedCounts = new Map();
const newFindings = [];
for (const diagnostic of diagnostics) {
  const key = diagnosticKey(repoRoot, diagnostic);
  const matched = matchedCounts.get(key) ?? 0;
  if (matched < (baseline.get(key) ?? 0)) matchedCounts.set(key, matched + 1);
  else newFindings.push(diagnostic);
}
if (newFindings.length === 0) {
  const currentCounts = new Map();
  for (const diagnostic of diagnostics) {
    const key = diagnosticKey(repoRoot, diagnostic);
    currentCounts.set(key, (currentCounts.get(key) ?? 0) + 1);
  }
  let stale = 0;
  const staleEntries = [];
  for (const [entry, count] of baseline) {
    if (scannedFiles && !scannedFiles.has(baselineEntryPath(entry))) continue;
    const missing = Math.max(0, count - (currentCounts.get(entry) ?? 0));
    stale += missing;
    for (let index = 0; index < missing; index += 1) staleEntries.push(entry);
  }
  if (stale > 0) {
    console.error("complexity gate: remove stale entries from the baseline:");
    for (const entry of staleEntries.sort()) console.error(`  ${entry}`);
    process.exit(1);
  }
  console.log(`complexity gate: ${diagnostics.length} finding${diagnostics.length === 1 ? "" : "s"} matched the grandfathered baseline`);
  process.exit(0);
}

console.error(
  `complexity gate: ${newFindings.length} new finding${newFindings.length === 1 ? "" : "s"} exceed complexity ${complexityLimit}`,
);
for (const diagnostic of newFindings) {
  const filename = diagnosticFilename(repoRoot, diagnostic);
  const line = diagnostic.labels?.[0]?.span?.line ?? 1;
  const message = String(diagnostic.message ?? "complexity exceeds the configured limit").replace(/\r?\n/g, " ");
  console.error(`::error file=web/${filename},line=${line},title=Oxlint complexity::${message}`);
}
process.exit(1);
