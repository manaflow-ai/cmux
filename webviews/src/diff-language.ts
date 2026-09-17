export type DiffLanguageResolver = (fileName: string) => string | null | undefined;

const textLanguage = "text";
const markdownLanguages = new Set(["markdown", "mdx"]);

const exactLanguageByName = new Map<string, string>([
  [".env", "dotenv"],
  ["appfile", "ruby"],
  ["bun.lock", "toml"],
  ["deliverfile", "ruby"],
  ["fastfile", "ruby"],
  ["gemfile", "ruby"],
  ["jenkinsfile", "groovy"],
  ["matchfile", "ruby"],
  ["podfile", "ruby"],
  ["pluginfile", "ruby"],
  ["scanfile", "ruby"],
  ["snapfile", "ruby"],
]);

const extensionLanguageByName = new Map<string, string>([
  ["adoc", "asciidoc"],
  ["asciidoc", "asciidoc"],
  ["gradle", "groovy"],
  ["markdown", "markdown"],
  ["md", "markdown"],
  ["mdown", "markdown"],
  ["mdx", "mdx"],
  ["mkd", "markdown"],
  ["mkdn", "markdown"],
  ["rst", "rst"],
  ["toml", "toml"],
]);

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
};

export function resolveDiffFileLanguage(
  filePath: string,
  parsedLanguage?: unknown,
  fallbackResolver?: DiffLanguageResolver,
): string {
  const explicitLanguage = stringLanguage(parsedLanguage);
  if (explicitLanguage != null && explicitLanguage !== textLanguage) {
    return explicitLanguage;
  }

  const cmuxLanguage = cmuxLanguageForFileName(filePath);
  if (cmuxLanguage != null) {
    return cmuxLanguage;
  }

  const fallbackLanguage = stringLanguage(fallbackResolver?.(filePath));
  if (fallbackLanguage != null) {
    return fallbackLanguage;
  }

  return explicitLanguage ?? textLanguage;
}

export function resolveDiffPreloadLanguages(
  filePath: string,
  parsedLanguage: unknown,
  fileDiff: DiffFileText | null | undefined,
  fallbackResolver?: DiffLanguageResolver,
): string[] {
  const fileLanguage = resolveDiffFileLanguage(filePath, parsedLanguage, fallbackResolver);
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

function cmuxLanguageForFileName(filePath: string): string | undefined {
  const basename = filePath.split(/[\\/]/).at(-1)?.trim().toLowerCase() ?? "";
  if (basename.length === 0) {
    return undefined;
  }

  const exactLanguage = exactLanguageByName.get(basename);
  if (exactLanguage != null) {
    return exactLanguage;
  }

  if (basename.startsWith(".env.")) {
    return "dotenv";
  }

  const extension = basename.includes(".") ? basename.split(".").at(-1) : undefined;
  return extension == null ? undefined : extensionLanguageByName.get(extension);
}

function stringLanguage(language: unknown): string | undefined {
  return typeof language === "string" && language.trim().length > 0
    ? language.trim()
    : undefined;
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
  return fencedLanguageByName.get(rawLanguage);
}
