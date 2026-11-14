// A browser oracle built separately from the measured production tree. Only public package APIs.
import { createHighlighterCore } from "@shikijs/core";
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript";
import { bundledLanguages, bundledLanguagesInfo } from "shiki/langs";

window.shikiSmoke = async () => {
  const highlighter = await createHighlighterCore({
    langs: [],
    themes: [
      {
        name: "probe",
        type: "dark",
        colors: { "editor.foreground": "#ffffff", "editor.background": "#000000" },
        tokenColors: [{ scope: "keyword", settings: { foreground: "#ff0000" } }],
      },
    ],
    engine: createJavaScriptRegexEngine({ forgiving: true }),
  });
  const languages = [];
  try {
    for (const { id } of bundledLanguagesInfo) {
      let timer;
      try {
        const grammar = await Promise.race([
          bundledLanguages[id](),
          new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(`language load timed out: ${id}`)), 15_000);
          }),
        ]);
        await highlighter.loadLanguage(grammar.default);
        const { tokens } = highlighter.codeToTokens('const answer = "hello";\n', { lang: id, theme: "probe" });
        languages.push({ id, tokens });
      } finally {
        clearTimeout(timer);
      }
    }
    return { aliases: Object.keys(bundledLanguages).sort(), languages };
  } finally {
    highlighter.dispose();
  }
};
