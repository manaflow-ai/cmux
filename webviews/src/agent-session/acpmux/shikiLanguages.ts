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
