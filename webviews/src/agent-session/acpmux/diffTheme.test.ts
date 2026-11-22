import { expect, test } from "bun:test";
import { createHighlighter } from "shiki";
import { syntaxThemes } from "./diffTheme";

/// Syntax colors are CSS variables over the terminal palette; Shiki must hand them
/// through to the rendered tokens (it swaps non-hex colors out and back in), or every
/// theme silently gets the fallbacks.
test("highlighted tokens carry the terminal palette variables", async () => {
  const highlighter = await createHighlighter({
    themes: [syntaxThemes.dark as never, syntaxThemes.light as never],
    langs: ["python", "diff"],
  });
  const colors = (code: string, lang: "python" | "diff", theme: string) =>
    highlighter
      .codeToTokens(code, { lang, theme })
      .tokens.flat()
      .map((token) => token.color ?? "");
  for (const theme of [syntaxThemes.dark.name, syntaxThemes.light.name]) {
    const python = colors('def greet():\n    return "hi"', "python", theme);
    expect(python.some((color) => color.startsWith("var(--agent-ansi-5,"))).toBe(true);
    expect(python.some((color) => color.startsWith("var(--agent-ansi-2,"))).toBe(true);
    const diff = colors("-old\n+new", "diff", theme);
    expect(diff.some((color) => color.startsWith("var(--agent-ansi-1,"))).toBe(true);
    expect(diff.some((color) => color.startsWith("var(--agent-ansi-2,"))).toBe(true);
  }
  highlighter.dispose();
});
