// The markdown editor's code highlighter: a grammar that finishes loading asks for one redraw, however
// many code blocks asked for it while it loaded. The editor's redraw colors every block again, and
// each block still waiting on its grammar asks again; when every ask chained its own redraw, the
// redraws multiplied with each grammar that landed, and a file with code in many languages (the
// gallery's markdown showcase: 234 blocks, 194 languages) froze the page.
import { expect, test } from "bun:test";
import { CodeHighlighter, markdownThemes } from "../src/pages/markdown/highlight";

const LANGUAGES = ["ts", "python", "rust", "go", "ruby", "java", "c", "bash"];
const BLOCKS_PER_LANGUAGE = 3;

test("each grammar that loads redraws the document once, not once per waiting block", async () => {
  const highlighter = new CodeHighlighter(markdownThemes());
  let redraws = 0;
  let colored!: () => void;
  const allColored = new Promise<void>((resolve) => (colored = resolve));
  // The editor plugin's redraw: color every code block again with the same refresh callback.
  const decorate = () => {
    let waiting = false;
    for (const language of LANGUAGES)
      for (let block = 0; block < BLOCKS_PER_LANGUAGE; block++)
        if (highlighter.tokens(`let value${block} = ${block};`, language, refresh) === null) waiting = true;
    if (!waiting) colored();
  };
  const refresh = () => {
    redraws++;
    decorate();
  };
  decorate();
  await allColored;
  // Every grammar has landed; redraws still chained to them run before the next macrotask.
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(redraws).toBeLessThanOrEqual(LANGUAGES.length);
});
