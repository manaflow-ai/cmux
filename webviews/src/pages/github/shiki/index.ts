// The `shiki` the GitHub page ships (scripts/cmux-next/build-pages-web.sh aliases `shiki` here):
// @pierre/diffs imports shiki's subpaths, each a file here (core.ts, langs.ts, textmate.ts,
// engine/, wasm.ts), and the page draws its inline diffs as plain text (GitHubFileDiff.tsx), so it needs Shiki's core and the JavaScript regex engine but no grammar.
// The agent pane's trimmed shiki (agent-session/acpmux/shiki) bundles about 2 MB of grammars,
// which would make the page six times as large for colours it does not draw.
import { createBundledHighlighter, createSingletonShorthands } from "@shikijs/core";
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript";

export * from "@shikijs/core";
export { createJavaScriptRegexEngine };

export function createOnigurumaEngine(): never {
  throw new Error("The GitHub page highlights with the JavaScript regex engine only");
}

import { bundledLanguages } from "./langs";

/// No grammars (langs.ts): Pierre renders every language as plain text.
export { bundledLanguages };

/// No bundled themes: the page registers the agent pane's (diffTheme.ts).
export const bundledThemes: Record<string, () => Promise<{ default: unknown }>> = {};

export const createHighlighter = createBundledHighlighter({
  langs: bundledLanguages as never,
  themes: bundledThemes as never,
  engine: () => createJavaScriptRegexEngine(),
});
export const { codeToHtml } = createSingletonShorthands(createHighlighter);
