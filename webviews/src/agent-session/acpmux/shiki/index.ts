// The `shiki` the bundled agent pane ships in place of the full package
// (scripts/cmux-next/build-agent-pane-web.sh aliases `shiki` here). @pierre/diffs imports
// shiki's subpaths, each a file here (core.ts, langs.ts, textmate.ts, engine/, wasm.ts); the
// full package bundles every grammar and theme and the WebAssembly engine, about 10 MB once
// inlined into the page. This keeps Pierre's imports, the
// JavaScript regex engine (the page's CSP allows no WebAssembly) and the languages in
// shikiLanguages.ts.
import { createBundledHighlighter, createSingletonShorthands } from "@shikijs/core";
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript";

export * from "@shikijs/core";
export { createJavaScriptRegexEngine };

export { createOnigurumaEngine } from "./engine/oniguruma";

import { bundledLanguages } from "./langs";

export { bundledLanguages };

/// No bundled themes: the pane registers its own (diffTheme.ts).
export const bundledThemes: Record<string, () => Promise<{ default: unknown }>> = {};

export const createHighlighter = createBundledHighlighter({
  langs: bundledLanguages as never,
  themes: bundledThemes as never,
  engine: () => createJavaScriptRegexEngine(),
});
export const { codeToHtml } = createSingletonShorthands(createHighlighter);
