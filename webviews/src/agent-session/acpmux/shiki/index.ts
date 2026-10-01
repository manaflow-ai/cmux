// The `shiki` the bundled agent pane ships in place of the full package
// (scripts/cmux-next/build-agent-pane-web.sh aliases `shiki` here). @pierre/diffs imports
// from `shiki`; the full package bundles every grammar and theme and the WebAssembly
// engine, about 10 MB once inlined into the page. This keeps Pierre's imports, the
// JavaScript regex engine (the page's CSP allows no WebAssembly) and common languages.
import { createBundledHighlighter, createSingletonShorthands } from "@shikijs/core";
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript";

export * from "@shikijs/core";
export { createJavaScriptRegexEngine };

export function createOnigurumaEngine(): never {
  throw new Error("The agent pane highlights with the JavaScript regex engine only");
}

const typescript = () => import("@shikijs/langs/typescript");
const javascript = () => import("@shikijs/langs/javascript");
const shellscript = () => import("@shikijs/langs/shellscript");
const markdown = () => import("@shikijs/langs/markdown");
const python = () => import("@shikijs/langs/python");
const yaml = () => import("@shikijs/langs/yaml");

/// Languages by Shiki id and common alias. A file in any other language shows as plain text.
export const bundledLanguages = {
  typescript, ts: typescript, mts: typescript, cts: typescript,
  tsx: () => import("@shikijs/langs/tsx"),
  javascript, js: javascript, mjs: javascript, cjs: javascript,
  jsx: () => import("@shikijs/langs/jsx"),
  json: () => import("@shikijs/langs/json"),
  jsonc: () => import("@shikijs/langs/jsonc"),
  markdown, md: markdown,
  css: () => import("@shikijs/langs/css"),
  scss: () => import("@shikijs/langs/scss"),
  html: () => import("@shikijs/langs/html"),
  shellscript, bash: shellscript, sh: shellscript, shell: shellscript, zsh: shellscript,
  python, py: python,
  rust: () => import("@shikijs/langs/rust"),
  go: () => import("@shikijs/langs/go"),
  swift: () => import("@shikijs/langs/swift"),
  yaml, yml: yaml,
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
} as Record<string, () => Promise<{ default: unknown }>>;

/// No bundled themes: the pane registers its own (diffTheme.ts).
export const bundledThemes: Record<string, () => Promise<{ default: unknown }>> = {};

export const createHighlighter = createBundledHighlighter({ langs: bundledLanguages as never, themes: bundledThemes as never, engine: () => createJavaScriptRegexEngine() });
export const { codeToHtml } = createSingletonShorthands(createHighlighter);
