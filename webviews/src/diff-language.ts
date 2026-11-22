import { bundledLanguages } from "shiki";
import { diffLanguages, type DiffLanguageRegistry } from "./diff-languages/registry";

const markdownLanguages = new Set(["markdown", "mdx"]);

const fencedLanguageByName = new Map<string, string>([
  ["bash", "shellscript"],
  ["c++", "cpp"],
  ["csharp", "csharp"],
  ["cs", "csharp"],
  ["dockerfile", "docker"],
  ["gql", "graphql"],
  ["groovy", "groovy"],
  ["js", "javascript"],
  ["kt", "kotlin"],
  ["md", "markdown"],
  ["objc", "objective-c"],
  ["patch", "diff"],
  ["py", "python"],
  ["rb", "ruby"],
  ["rs", "rust"],
  ["sh", "shellscript"],
  ["shell", "shellscript"],
  ["swift", "swift"],
  ["ts", "typescript"],
  ["yml", "yaml"],
  ["zsh", "shellscript"],
]);

for (const language of [
  "c",
  "clojure",
  "coffee",
  "cpp",
  "css",
  "dart",
  "diff",
  "docker",
  "elixir",
  "erlang",
  "fsharp",
  "go",
  "graphql",
  "handlebars",
  "html",
  "ini",
  "java",
  "javascript",
  "json",
  "jsonc",
  "jsonl",
  "julia",
  "kotlin",
  "latex",
  "less",
  "log",
  "lua",
  "make",
  "markdown",
  "mdx",
  "perl",
  "php",
  "powershell",
  "pug",
  "python",
  "r",
  "ruby",
  "rust",
  "scala",
  "scss",
  "shellscript",
  "sql",
  "swift",
  "toml",
  "tsx",
  "typescript",
  "xml",
  "yaml",
]) {
  fencedLanguageByName.set(language, language);
}

type DiffFileText = {
  additionLines?: unknown;
  deletionLines?: unknown;
  hunks?: unknown;
};

/// The Shiki language for one file of a diff (`text` when none applies). `fileDiff` lends its
/// first line to `#!` detection.
export function resolveDiffFileLanguage(
  filePath: string,
  parsedLanguage?: unknown,
  fileDiff?: DiffFileText | null,
  registry: DiffLanguageRegistry = diffLanguages,
): string {
  return registry.detect({ path: filePath, parsedLanguage, firstLine: firstFileLine(fileDiff) });
}

export function resolveDiffPreloadLanguages(
  filePath: string,
  parsedLanguage: unknown,
  fileDiff: DiffFileText | null | undefined,
  registry: DiffLanguageRegistry = diffLanguages,
): string[] {
  const fileLanguage = resolveDiffFileLanguage(filePath, parsedLanguage, fileDiff, registry);
  const languages = new Set([fileLanguage]);
  if (markdownLanguages.has(fileLanguage)) {
    for (const language of markdownFenceLanguages(fileDiff)) {
      languages.add(language);
    }
  }
  return Array.from(languages);
}

export function markdownFenceLanguages(fileDiff: DiffFileText | null | undefined): string[] {
  const languages = new Set<string>();
  for (const line of diffTextLines(fileDiff)) {
    const language = markdownFenceLanguage(line);
    if (language != null) {
      languages.add(language);
    }
  }
  return Array.from(languages);
}

/// Line 1 of either side, when a hunk starts there (a patch only carries hunk lines).
export function firstFileLine(fileDiff: DiffFileText | null | undefined): string | undefined {
  const hunk = Array.isArray(fileDiff?.hunks) ? (fileDiff.hunks[0] as Record<string, unknown> | undefined) : undefined;
  const side = (start: unknown, index: unknown, lines: unknown) =>
    start === 1 && typeof index === "number" && Array.isArray(lines) && typeof lines[index] === "string"
      ? (lines[index] as string).replace(/\r?\n$/, "")
      : undefined;
  if (hunk == null) {
    const lines = Array.isArray(fileDiff?.additionLines) ? fileDiff.additionLines : fileDiff?.deletionLines;
    return Array.isArray(lines) && typeof lines[0] === "string" ? lines[0].replace(/\r?\n$/, "") : undefined;
  }
  return (
    side(hunk.additionStart, hunk.additionLineIndex, fileDiff?.additionLines) ??
    side(hunk.deletionStart, hunk.deletionLineIndex, fileDiff?.deletionLines)
  );
}

function diffTextLines(fileDiff: DiffFileText | null | undefined): string[] {
  const lines: string[] = [];
  appendTextLines(lines, fileDiff?.additionLines);
  appendTextLines(lines, fileDiff?.deletionLines);
  return lines;
}

function appendTextLines(target: string[], value: unknown): void {
  if (!Array.isArray(value)) {
    return;
  }
  for (const line of value) {
    if (typeof line === "string") {
      target.push(line.replace(/\r?\n$/, ""));
    }
  }
}

function markdownFenceLanguage(line: string): string | undefined {
  const match = line.match(/^\s{0,3}(`{3,}|~{3,})\s*([^`~\s]+)?/);
  if (match == null || match[2] == null) {
    return undefined;
  }
  const rawLanguage = match[2]
    .replace(/^\{\.?/, "")
    .replace(/[},].*$/, "")
    .trim()
    .toLowerCase();
  return (
    fencedLanguageByName.get(rawLanguage) ??
    (Object.prototype.hasOwnProperty.call(bundledLanguages, rawLanguage) ? rawLanguage : undefined)
  );
}
