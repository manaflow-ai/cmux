// `shiki/langs` for the bundled agent pane (the build aliases `shiki` to this folder): the
// languages in shikiLanguages.ts, each grammar loaded on demand. @pierre/diffs 1.6 resolves a
// language from here; index.ts re-exports it for `shiki` itself. Nothing here imports index.ts,
// so a bundle that reaches only this file keeps no highlighter factory.

import { HIGHLIGHTED_LANGUAGES } from "../shikiLanguages";

// Static imports by id, so the bundler includes exactly these grammars.
const loaders: Record<string, () => Promise<{ default: unknown }>> = {
  typescript: () => import("@shikijs/langs/typescript"),
  tsx: () => import("@shikijs/langs/tsx"),
  javascript: () => import("@shikijs/langs/javascript"),
  jsx: () => import("@shikijs/langs/jsx"),
  json: () => import("@shikijs/langs/json"),
  jsonc: () => import("@shikijs/langs/jsonc"),
  markdown: () => import("@shikijs/langs/markdown"),
  css: () => import("@shikijs/langs/css"),
  scss: () => import("@shikijs/langs/scss"),
  html: () => import("@shikijs/langs/html"),
  shellscript: () => import("@shikijs/langs/shellscript"),
  python: () => import("@shikijs/langs/python"),
  rust: () => import("@shikijs/langs/rust"),
  go: () => import("@shikijs/langs/go"),
  swift: () => import("@shikijs/langs/swift"),
  yaml: () => import("@shikijs/langs/yaml"),
  toml: () => import("@shikijs/langs/toml"),
  sql: () => import("@shikijs/langs/sql"),
  diff: () => import("@shikijs/langs/diff"),
  c: () => import("@shikijs/langs/c"),
  java: () => import("@shikijs/langs/java"),
  kotlin: () => import("@shikijs/langs/kotlin"),
  zig: () => import("@shikijs/langs/zig"),
  lua: () => import("@shikijs/langs/lua"),
  make: () => import("@shikijs/langs/make"),
  dockerfile: () => import("@shikijs/langs/dockerfile"),
};

/// Languages by Shiki id and alias (shikiLanguages.ts). Pierre renders any other as plain text.
export const bundledLanguages = Object.fromEntries(
  Object.entries(HIGHLIGHTED_LANGUAGES).flatMap(([id, aliases]) => [id, ...aliases].map((name) => [name, loaders[id]])),
);
