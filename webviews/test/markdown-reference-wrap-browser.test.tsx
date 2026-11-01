// A `repo#N` reference that a reply hard-wraps at its `#` (Leo 2026-10-31, on "the sent-message
// cards (cmux#\n29613) and the bottom-gap fix": "WTF HAPPENED WITH THIS" / "F***ING TEXT????").
// The next line's "29613)" read as an ordered list's number, so the number drew bold and absolutely
// positioned over "and". The reply stays one paragraph, the reference one run of text, and in Chromium
// with the real stylesheets, at every width that wraps the line near the reference, `cmux#29613` sits
// on one line and no two words overlap.
import { readFileSync } from "node:fs";
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { Markdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-reference-wrap-browser.test.tsx", async () => {
  setDefaultTimeout(90_000);
  const REPLY =
    "Several fixes are stuck on that: the sent-message cards (cmux#\n" +
    "29613) and the bottom-gap fix (cmux#28905), with the model picker likely next.";
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("markdown-reference-wrap-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("reference wrap", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/chips/chips.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  describe("in Chromium", () => {
    test("the reference wraps whole and no words overlap, at every width", async () => {
      const html = renderToStaticMarkup(<Markdown githubRepository="manaflow-ai/cmux">{REPLY}</Markdown>);
      const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
      try {
        await page.setContent(
          `<html><head><style>${css}</style></head><body><div id="column" style="font-size:15px">${html}</div></body></html>`,
        );
        // Widths from where "(cmux#29613)" ends the first line to where it is pushed to the second.
        const results = await page.evaluate(() => {
          const column = document.getElementById("column")!;
          const out: { width: number; numbers: number; chipLines: number; overlap: string | null; label: string }[] =
            [];
          for (let width = 260; width <= 620; width += 2) {
            column.style.width = `${width}px`;
            // The reference as drawn: a chip when its repository is known, else text; either way
            // "cmux#" and "29613" are one run that sits on one line.
            let label = "";
            let chipLines = 0;
            const finder = document.createTreeWalker(column, NodeFilter.SHOW_TEXT);
            for (let node = finder.nextNode(); node; node = finder.nextNode()) {
              const at = (node.textContent ?? "").indexOf("cmux#29613");
              if (at < 0) continue;
              const range = document.createRange();
              range.setStart(node, at);
              range.setEnd(node, at + "cmux#29613".length);
              label = range.toString();
              chipLines = new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top)))
                .size;
              break;
            }
            // Every word's boxes; two words of the paragraph never share pixels.
            const boxes: { word: string; rect: DOMRect }[] = [];
            const walker = document.createTreeWalker(column, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              const text = node.textContent ?? "";
              for (const match of text.matchAll(/\S+/g)) {
                const range = document.createRange();
                range.setStart(node, match.index!);
                range.setEnd(node, match.index! + match[0].length);
                for (const rect of range.getClientRects()) if (rect.width > 0) boxes.push({ word: match[0], rect });
              }
            }
            let overlap: string | null = null;
            for (let a = 0; a < boxes.length && !overlap; a++)
              for (let b = a + 1; b < boxes.length; b++) {
                const x = boxes[a]!.rect;
                const y = boxes[b]!.rect;
                if (
                  x.left < y.right - 0.5 &&
                  y.left < x.right - 0.5 &&
                  x.top < y.bottom - 0.5 &&
                  y.top < x.bottom - 0.5
                ) {
                  overlap = `${boxes[a]!.word} / ${boxes[b]!.word}`;
                  break;
                }
              }
            out.push({
              width,
              numbers: column.querySelectorAll(".cv-li__num").length,
              chipLines,
              overlap,
              label,
            });
          }
          return out;
        });
        for (const result of results) {
          expect({ width: result.width, numbers: result.numbers }).toEqual({ width: result.width, numbers: 0 });
          expect({ width: result.width, label: result.label }).toEqual({ width: result.width, label: "cmux#29613" });
          expect({ width: result.width, chipLines: result.chipLines }).toEqual({ width: result.width, chipLines: 1 });
          expect({ width: result.width, overlap: result.overlap }).toEqual({ width: result.width, overlap: null });
        }
      } finally {
        await page.close();
      }
    });
    test("closes the browser", async () => {
      await browser.close();
    });
  });
});
