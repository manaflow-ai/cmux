// The chat column (chatWidth.ts): Settings > Agents > Chat Layout > Chat Text Width
// (`agentPane.display.width`) sets every chat's column, its default 800 too, capped only by the pane;
// Chat Full Width fills the pane (https://github.com/manaflow-ai/cmux/issues/36299). Everything in the
// chat shares that one column (#20391's edge): the transcript, its prose and the composer. The gallery's
// agent-pane.chat-width frames at 900, 1440 and 1920 pane widths, which also log density numbers
// (characters per prose line, gutter, tool row height).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Measured = {
  pane: number;
  column: { left: number; width: number };
  gutter: number;
  composer: { left: number; width: number };
  prose: number;
  charsPerLine: number;
  lines: number;
  code: number;
  table: number;
  bubbleMax: number;
  toolRow: number;
  turnGap: number;
};

await requireBrowserLane("agent-pane-chat-width.test.ts", async () => {
  /** Runs in the page: the column, its blocks and the density numbers. */
  function measure(): Measured {
    const averageChar = (element: Element) => {
      const style = getComputedStyle(element);
      const context = document.createElement("canvas").getContext("2d")!;
      context.font = `${style.fontSize} ${style.fontFamily}`;
      const text = element.textContent ?? "";
      return context.measureText(text).width / Math.max(1, text.length) + (parseFloat(style.letterSpacing) || 0);
    };
    const rect = (selector: string) => document.querySelector(selector)?.getBoundingClientRect();
    const rowElement = document.querySelector<HTMLElement>(".acpmux-row")!;
    const row = rowElement.getBoundingClientRect();
    const pane = rect(".acpmux-scroll")!;
    const composer = rect(".acpmux-composer-box")!;
    const paragraph = document.querySelector(".cv-md > .cv-p")!;
    const range = document.createRange();
    range.selectNodeContents(paragraph);
    const lines = new Set([...range.getClientRects()].map((line) => Math.round(line.top))).size;
    const tools = [...document.querySelectorAll<HTMLElement>(".cv-tool")];
    const user = rect(".cv-user__bubble")!;
    const firstStep = document.querySelectorAll(".acpmux-row")[1]?.getBoundingClientRect();
    return {
      pane: (rowElement.offsetParent as HTMLElement).clientWidth,
      column: { left: row.left - pane.left, width: row.width },
      gutter: row.left - pane.left,
      composer: { left: composer.left - pane.left, width: composer.width },
      prose: paragraph.getBoundingClientRect().width,
      // The prose width over the paragraph's average character width in its own font.
      charsPerLine: Math.round(paragraph.getBoundingClientRect().width / averageChar(paragraph)),
      lines,
      code: rect(".cv-codeblock")?.width ?? 0,
      table: rect(".cv-table-wrap")?.width ?? 0,
      bubbleMax: Math.round(
        (row.width * (parseFloat(getComputedStyle(document.querySelector(".cv-user__bubble")!).maxWidth) || 0)) / 100,
      ),
      toolRow:
        tools[0]?.getBoundingClientRect().height ??
        rect(".cv-worked, .cv-summary, .acpmux-row:nth-child(2)")?.height ??
        0,
      turnGap: firstStep ? Math.round(firstStep.top - user.bottom) : 0,
    };
  }

  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-chat-width: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat width", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.chat-width", { variant, width })}`;

  const open = async (variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 900 } });
    for (;;) {
      try {
        await page.goto(url(variant, width));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.locator(".cv-codeblock").first().waitFor();
    return page;
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.chat-width", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const at = async (variant: string, width: number) => {
    const page = await open(variant, width);
    const measured = await page.evaluate(measure);
    await page.close();
    console.log(`chat-width ${variant} @${width}: ${JSON.stringify(measured)}`);
    return measured;
  };

  /// The column `--cv-column: clamp(min(720px, cap), 100%, cap)` draws in a pane of `pane` px.
  const column = (pane: number, cap: number) => {
    const span = Math.min(cap, Math.max(Math.min(720, cap), pane));
    return pane - 2 * Math.max(16, (pane - span) / 2);
  };

  const widths = { standard: 800, narrow: 640, wide: 960 } as const;
  // Panes narrower than the setting (360 to 760; 640's at 600, 960's at 900): the column is the pane
  // less its page edges, never wider than the pane, and the composer stays on it.
  for (const [variant, width] of [
    ["standard", 360],
    ["standard", 600],
    ["standard", 760],
    ["narrow", 600],
    ["wide", 900],
  ] as const)
    test(`${variant} fits a ${width}px pane, the pane less its page edges`, async () => {
      const m = await at(variant, width);
      expect(m.column.width).toBeCloseTo(m.pane - 32, -0.3);
      expect(m.column.width).toBeLessThanOrEqual(m.pane);
      expect(m.composer.left).toBeCloseTo(m.column.left, -0.3);
    });

  /** Runs in the page: the lines of text that draw past their row (a row is the chat's column and clips
   *  its own paint, so text past it is cut off; a word that does not break overflows its paragraph's
   *  box, not the box itself), the elements that draw past the pane (a control's box may overhang the
   *  column by design: a prompt's last action button by its glyph's inset, conversation.css
   *  --cv-footer-overhang), each unless a box that scrolls on its own (a code block, a table) holds it;
   *  and how far the transcript itself scrolls sideways. */
  function overflow() {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const pane = scroller.getBoundingClientRect();
    const row = (node: Node) => node.parentElement?.closest("[data-row-id]")?.getBoundingClientRect() ?? pane;
    const inside = (box: DOMRect, edge: DOMRect) => box.right <= edge.right + 0.5 && box.left >= edge.left - 0.5;
    const outside = (box: DOMRect, edge: DOMRect) => box.width > 0 && !inside(box, edge);
    const held = (node: Node, edge: DOMRect) => {
      for (let parent = node.parentElement; parent && parent !== scroller; parent = parent.parentElement) {
        if (parent.matches("[data-row-id]")) return false;
        if (getComputedStyle(parent).overflowX === "visible") continue;
        return inside(parent.getBoundingClientRect(), edge);
      }
      return false;
    };
    const name = (element: Element | null) => (element ? String(element.className) || element.tagName : "?");
    const spills: string[] = [];
    for (const element of scroller.querySelectorAll<HTMLElement>("*")) {
      const box = element.getBoundingClientRect();
      if (outside(box, pane) && !held(element, pane))
        spills.push(`${name(element)} ${Math.round(box.left)}..${Math.round(box.right)}`);
    }
    const walker = document.createTreeWalker(scroller, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      const edge = row(text);
      range.selectNodeContents(text);
      const line = [...range.getClientRects()].find((box) => outside(box, edge));
      if (line && !held(text, edge))
        spills.push(`text in ${name(text.parentElement)} ${Math.round(line.left)}..${Math.round(line.right)}`);
    }
    return { sideways: scroller.scrollWidth - scroller.clientWidth, spills: spills.slice(0, 5) };
  }

  // Content that cannot wrap (an unbroken 263-character token, a long URL, a wide table, a one-line
  // command) at the narrowest pane, a usual one and a wide one, and at Full Width: it stays inside the
  // pane, and the transcript never scrolls sideways.
  for (const [variant, width] of [
    ["overflow", 360],
    ["overflow", 900],
    ["overflow", 1920],
    ["overflow-full-width", 900],
    ["overflow-full-width", 2560],
  ] as const)
    test(`${variant}: content that cannot wrap stays inside a ${width}px pane`, async () => {
      const page = await open(variant, width);
      const result = await page.evaluate(overflow);
      await page.close();
      console.log(`chat-width ${variant} @${width}: ${JSON.stringify(result)}`);
      expect(result).toEqual({ sideways: 0, spills: [] });
    });

  for (const width of [900, 1440, 1920]) {
    for (const [variant, cap] of Object.entries(widths))
      test(`${variant} draws its ${cap}px Chat Text Width at ${width}`, async () => {
        const m = await at(variant, width);
        expect(m.column.width).toBeCloseTo(column(m.pane, cap), -0.3);
        // The column is the setting wherever the pane fits it, never a share of the pane.
        if (m.pane >= cap + 32) expect(Math.abs(m.column.width - cap)).toBeLessThan(8);
        expect(m.composer.left).toBeCloseTo(m.column.left, -0.3);
        expect(m.prose).toBeCloseTo(m.column.width, -0.3);
      });

    test(`full width fills the pane at ${width}`, async () => {
      const m = await at("full-width", width);
      expect(m.column.width).toBeCloseTo(m.pane - 32, -0.3);
      expect(m.composer.left).toBeCloseTo(m.column.left, -0.3);
    });
  }
});
