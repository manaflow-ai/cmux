// An agent reply's unlabeled fence holding a tree drawn in box-drawing characters (Leo 2026-11-01:
// "could we render this type of thing better in cmux-next"). In Chromium with the real stylesheets:
// each │, ├ and └ meets the one on the next line (no band between lines), a 200-character line
// scrolls inside the card instead of running past its right edge, and the unlabeled card has no
// "Plain text" header row; its copy floats in the corner and shows on hover.
import { readFileSync } from "node:fs";
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser, type Page } from "playwright";
import { Markdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { codeCardHeight } from "../src/agent-session/acpmux/model";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("code-block-diagram-browser.test.tsx", async () => {
  setDefaultTimeout(90_000);
  const LONG = `└─ ${"x".repeat(196)}!`;
  const TREE = [
    "Your Mac",
    "├─ cmux NEXT app ── Swift window/chrome + web views",
    "│     talks to ↓ (local sockets)",
    "├─ cmux-tui  (one Rust binary, two daemons)",
    "│   ├─ terminal daemon: workspaces, panes, PTYs",
    "│   └─ acpmux: the agent daemon",
    "│",
    LONG,
  ].join("\n");
  const REPLY = `Here's how it fits together today.\n\n\`\`\`\n${TREE}\n\`\`\`\n`;
  expect(LONG.length).toBe(200);

  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("code-block-diagram-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("code block diagram", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  const open = async (): Promise<Page> => {
    const html = renderToStaticMarkup(<Markdown>{REPLY}</Markdown>);
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await page.setContent(
      `<html><head><style>${css}</style></head><body><div id="column" style="width:560px;font-size:14px">${html}</div></body></html>`,
    );
    return page;
  };

  describe("in Chromium", () => {
    test("each box-drawing connector meets the one on the next line", async () => {
      const page = await open();
      try {
        const gaps = await page.evaluate(() => {
          const lines = [...document.querySelectorAll<HTMLElement>(".cv-codeblock .cv-code-plain__line")];
          const box = (line: HTMLElement, at: number) => {
            const node = line.firstChild!;
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + 1);
            return range.getBoundingClientRect();
          };
          const out: { line: number; column: number; gap: number }[] = [];
          for (let index = 0; index + 1 < lines.length; index++) {
            const upper = lines[index]!.textContent ?? "";
            const lower = lines[index + 1]!.textContent ?? "";
            for (let column = 0; column < upper.length; column++) {
              // A vertical stroke that continues down: │ or ├ above, │, ├ or └ below.
              if (!"│├".includes(upper[column]!) || !"│├└".includes(lower[column] ?? "")) continue;
              const top = box(lines[index]!, column);
              const bottom = box(lines[index + 1]!, column);
              out.push({ line: index, column, gap: Math.round((bottom.top - top.bottom) * 100) / 100 });
            }
          }
          return out;
        });
        // The fixture has six such joins (│ under ├ in column 0, and the inner ├ over └).
        expect(gaps.length).toBeGreaterThanOrEqual(6);
        for (const join of gaps) expect({ ...join, touches: join.gap <= 0.5 }).toEqual({ ...join, touches: true });
      } finally {
        await page.close();
      }
    });

    test("a 200-character line scrolls inside the card and nothing is clipped", async () => {
      const page = await open();
      try {
        const result = await page.evaluate(() => {
          const column = document.getElementById("column")!.getBoundingClientRect();
          const card = document.querySelector<HTMLElement>(".cv-codeblock")!;
          const pre = card.querySelector<HTMLElement>(".cv-code-plain")!;
          const before = { scrollWidth: pre.scrollWidth, clientWidth: pre.clientWidth };
          pre.scrollLeft = pre.scrollWidth;
          const line = [...pre.querySelectorAll<HTMLElement>(".cv-code-plain__line")].at(-1)!;
          const node = line.firstChild!;
          const range = document.createRange();
          range.setStart(node, (node.textContent ?? "").length - 1);
          range.setEnd(node, (node.textContent ?? "").length);
          const last = range.getBoundingClientRect();
          const scroller = pre.getBoundingClientRect();
          const cardBox = card.getBoundingClientRect();
          return {
            diagramCard: card.classList.contains("cv-codeblock--diagram"),
            overflowX: getComputedStyle(pre).overflowX,
            whiteSpace: getComputedStyle(pre).whiteSpace,
            scrolls: before.scrollWidth > before.clientWidth,
            cardInColumn: cardBox.right <= column.right + 0.5,
            scrollerInCard: scroller.right <= cardBox.right + 0.5,
            lastCharShown: last.right <= scroller.right + 0.5 && last.left >= scroller.left - 0.5,
          };
        });
        expect(result).toEqual({
          diagramCard: true,
          overflowX: "auto",
          whiteSpace: "pre",
          scrolls: true,
          cardInColumn: true,
          scrollerInCard: true,
          lastCharShown: true,
        });
      } finally {
        await page.close();
      }
    });

    test("an unlabeled card has no header row; its copy shows on hover", async () => {
      const page = await open();
      try {
        const state = () =>
          page.evaluate(() => {
            const card = document.querySelector<HTMLElement>(".cv-codeblock")!;
            const header = card.querySelector<HTMLElement>(".cv-codeblock__header")!;
            const body = card.querySelector<HTMLElement>(".cv-codeblock__body")!;
            const style = getComputedStyle(header);
            return {
              label: [...header.childNodes]
                .filter((node) => !(node instanceof Element && node.matches(".cv-codeblock__actions")))
                .map((node) => node.textContent)
                .join("")
                .trim(),
              icon: header.querySelector(":scope > svg") !== null,
              copy: header.querySelector(".cv-codeblock__actions button") !== null,
              // The header floats over the body instead of taking a row above it.
              inFlow: style.position !== "absolute",
              shown: style.opacity === "1" && style.visibility !== "hidden",
              bodyTop: Math.round(body.getBoundingClientRect().top - card.getBoundingClientRect().top),
            };
          });
        const rest = await state();
        expect(rest).toEqual({ label: "", icon: false, copy: true, inFlow: false, shown: false, bodyTop: 13 });
        await page.addStyleTag({ content: "*{transition:none!important}" });
        await page.hover(".cv-codeblock__body");
        expect((await state()).shown).toBe(true);
      } finally {
        await page.close();
      }
    });

    test("the virtual transcript's estimate matches the drawn card", async () => {
      const page = await open();
      try {
        const drawn = await page.evaluate(() => {
          const card = document.querySelector<HTMLElement>(".cv-codeblock")!;
          const pre = card.querySelector<HTMLElement>(".cv-code-plain")!;
          return {
            height: card.getBoundingClientRect().height,
            width: card.getBoundingClientRect().width,
            scrollbar: pre.offsetHeight - pre.clientHeight,
          };
        });
        // The estimate reserves a 15px scrollbar for a line wider than the card; Chromium's may differ.
        const estimate = codeCardHeight(TREE, "", drawn.width) - 15 + drawn.scrollbar;
        expect(Math.abs(estimate - drawn.height)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });

    test("a labeled fence keeps its header row and label", async () => {
      const html = renderToStaticMarkup(<Markdown>{"```python\nprint('│')\n```\n"}</Markdown>);
      const page = await browser.newPage({ viewport: { width: 900, height: 400 } });
      try {
        await page.setContent(
          `<html><head><style>${css}</style></head><body><div id="column">${html}</div></body></html>`,
        );
        const header = await page.evaluate(() => {
          const header = document.querySelector<HTMLElement>(".cv-codeblock__header")!;
          const label = header.querySelector(":scope > span:not(.cv-codeblock__actions)");
          return { text: label?.textContent?.trim(), inFlow: getComputedStyle(header).position !== "absolute" };
        });
        expect(header).toEqual({ text: "Python", inFlow: true });
      } finally {
        await page.close();
      }
    });

    test("closes the browser", async () => {
      await browser.close();
    });
  });
});
