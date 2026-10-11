// The `shiki` the bundled agent pane ships in place of the full package
// (scripts/cmux-next/build-agent-pane-web.sh aliases `shiki` here). @pierre/diffs imports
// from `shiki`; the full package bundles every grammar and theme and the WebAssembly
// engine, about 10 MB once inlined into the page. This keeps Pierre's imports, the
// JavaScript regex engine (the page's CSP allows no WebAssembly) and the languages in
// shikiLanguages.ts.
import { createBundledHighlighter, createSingletonShorthands } from "@shikijs/core";
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript";

export * from "@shikijs/core";
export { createJavaScriptRegexEngine };

export function createOnigurumaEngine(): never {
  throw new Error("The agent pane highlights with the JavaScript regex engine only");
}

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

/// No bundled themes: the pane registers its own (diffTheme.ts).
export const bundledThemes: Record<string, () => Promise<{ default: unknown }>> = {};

export const createHighlighter = createBundledHighlighter({
  langs: bundledLanguages as never,
  themes: bundledThemes as never,
  engine: () => createJavaScriptRegexEngine(),
});
export const { codeToHtml } = createSingletonShorthands(createHighlighter);
