#!/usr/bin/env node

const { execFileSync } = require("node:child_process");
const { existsSync, readFileSync, statSync } = require("node:fs");
const path = require("node:path");

const stylesheetExtensions = new Set([".css", ".scss", ".sass", ".less"]);

function git(args) {
  try {
    return execFileSync("git", args, { encoding: "utf8" })
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function unique(values) {
  return Array.from(new Set(values));
}

function isStylesheet(file) {
  return stylesheetExtensions.has(path.extname(file));
}

function changedStylesheets() {
  return unique([
    ...git(["diff", "--name-only", "--diff-filter=ACMRT", "HEAD"]),
    ...git(["ls-files", "--others", "--exclude-standard"]),
  ]).filter((file) => isStylesheet(file) && existsSync(file) && statSync(file).isFile());
}

function stripCssComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, "");
}

const rawValuePatterns = [
  /#[0-9a-fA-F]{3,8}\b/,
  /\b(?:rgb|rgba|hsl|hsla|lab|lch|oklab|oklch|color-mix)\(/i,
  /(?:^|[^\w.-])-?\d*\.?\d+(?:px|rem|em|vh|vw|vmin|vmax|ch|ex|%|s|ms|deg|rad|turn)\b/,
];

function declarationFromLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("@") || trimmed.startsWith("}") || trimmed.endsWith("{")) {
    return null;
  }

  const colon = trimmed.indexOf(":");
  if (colon === -1) {
    return null;
  }

  const property = trimmed.slice(0, colon).trim();
  if (!property || property.startsWith("--")) {
    return null;
  }

  const value = trimmed
    .slice(colon + 1)
    .replace(/[;}].*$/, "")
    .trim();
  if (!value) {
    return null;
  }

  return { property, value };
}

function auditStylesheet(file) {
  const source = stripCssComments(readFileSync(file, "utf8"));
  const violations = [];
  source.split(/\r?\n/).forEach((line, index) => {
    const declaration = declarationFromLine(line);
    if (!declaration) {
      return;
    }
    if (!rawValuePatterns.some((pattern) => pattern.test(declaration.value))) {
      return;
    }
    violations.push({
      file,
      line: index + 1,
      property: declaration.property,
      value: declaration.value,
    });
  });
  return violations;
}

const files = changedStylesheets();
if (files.length === 0) {
  console.log("token-audit: no changed stylesheet files to audit");
  process.exit(0);
}

const violations = files.flatMap(auditStylesheet);
if (violations.length === 0) {
  console.log(`token-audit: audited ${files.length} changed stylesheet file(s); no raw CSS values found`);
  process.exit(0);
}

console.error("token-audit: raw CSS values found in changed stylesheet files");
for (const violation of violations) {
  console.error(
    `${violation.file}:${violation.line} ${violation.property}: ${violation.value} ` +
      "(use var(--token-name))"
  );
}
process.exit(1);
