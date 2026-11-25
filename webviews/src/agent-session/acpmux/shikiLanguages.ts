// Languages the bundled pane highlights (acpmux/shiki aliases `shiki` to these). A file in
// any other language renders as plain text: Pierre throws for a language Shiki lacks.

/// Shiki language ids shipped in the bundle, each with the aliases that resolve to it.
export const HIGHLIGHTED_LANGUAGES: Record<string, string[]> = {
  typescript: ["ts", "mts", "cts"],
  tsx: [],
  javascript: ["js", "mjs", "cjs"],
  jsx: [],
  json: [],
  jsonc: [],
  markdown: ["md"],
  css: [],
  scss: [],
  html: [],
  shellscript: ["bash", "sh", "shell", "zsh"],
  python: ["py"],
  rust: [],
  go: [],
  swift: [],
  yaml: ["yml"],
  toml: [],
  sql: [],
  diff: [],
  c: [],
  java: [],
  kotlin: [],
  zig: [],
  lua: [],
  make: ["makefile"],
  dockerfile: [],
};

const highlighted = new Set(Object.entries(HIGHLIGHTED_LANGUAGES).flatMap(([id, aliases]) => [id, ...aliases]));

export const isHighlighted = (lang: string) => highlighted.has(lang);

/// Names whose language is not their extension.
const BY_NAME: Record<string, string> = { makefile: "make", dockerfile: "dockerfile" };
/// Extensions that name a bundled language under another id; any other extension that is one of
/// the bundle's ids or aliases is its own language.
const BY_EXTENSION: Record<string, string> = {
  rs: "rust",
  h: "c",
  kt: "kotlin",
  kts: "kotlin",
  htm: "html",
  yml: "yaml",
  sh: "shellscript",
  zsh: "shellscript",
  bash: "shellscript",
};

/// The bundled language a file is highlighted in, by its name, else "text" (a read's lines,
/// conversation/HighlightedLines.tsx). Read here rather than through Pierre's own table, so it needs
/// nothing of @pierre/diffs.
export function fileLanguage(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1).toLowerCase();
  if (BY_NAME[name]) return BY_NAME[name];
  const extension = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : "";
  const lang = BY_EXTENSION[extension] ?? extension;
  return lang && isHighlighted(lang) ? lang : "text";
}
