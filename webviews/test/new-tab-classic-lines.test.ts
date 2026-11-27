// The classic New Tab page's lines (leo-workspace design/grid.md rules 2 and 6, section 2): render
// the real NewTabPage with its real model chips through the pane's mock transport and measure ink.
//  - No hairline under (or over) the rounded box runs past its corners: the box draws its own edge,
//    so a stacked part never adds a line at the box's edge that sticks out where the corners round.
//  - The page has one left line, `--acpmux-newtab-lead` in from the box's edge (on the 4 px grid):
//    "All sessions" starts its ink on it to 0.5 px, and the field row's leading glyph's ink sits on it
//    within its own side bearing (1 px).
//  - The quiet row's permission mode chip continues that column: its shield centers on the row glyph's
//    center line (`--acpmux-newtab-mark`) to 0.5 px and its first ink sits on the lead within 1 px, in
//    the stepped and the plain footer looks.
// Leo, 2026-10-29: "we need to have better grids ... We need to have the fucking shit aligned on
// fucking grids and lines".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Lines = {
  box: { left: number; right: number; top: number; bottom: number; radius: number };
  hairlines: { owner: string; y: number; left: number; right: number }[];
  lead: number;
  glyph: number;
  allSessions: number;
  /** The permission mode chip under the box: its leading glyph's ink (stepped look) and its label's. */
  mode: { glyph: number | null; text: number; chip: number; center: number | null } | null;
  /** The field row's leading glyph box's center. */
  glyphCenter: number;
  /** --acpmux-newtab-mark: the leading marks' center line. */
  mark: number;
};

await requireBrowserLane("new-tab-classic-lines.test.ts", async () => {
  setDefaultTimeout(180_000);
  // The page's lines, read in the page (the browser-lane check keeps every helper inside this call).
  async function measure(page: Page): Promise<Lines> {
    return page.evaluate(() => {
      const root = document.querySelector<HTMLElement>(".acpmux-newtab")!;
      const box = root.querySelector<HTMLElement>(".acpmux-newtab-box")!;
      const boxRect = box.getBoundingClientRect();
      const radius = parseFloat(getComputedStyle(box).borderBottomLeftRadius) || 0;
      const name = (node: Element) =>
        `${node.tagName.toLowerCase()}${[...node.classList].map((one) => `.${one}`).join("")}`;
      const visible = (width: string, style: string, color: string) =>
        parseFloat(width) > 0 && style !== "none" && style !== "hidden" && !/^rgba\(.*,\s*0\)$|transparent/.test(color);

      // Every horizontal border drawn at the box's top or bottom edge (within 3 px), the box's own
      // excepted (it draws its edge as an inset shadow that follows the radius).
      const hairlines: Lines["hairlines"] = [];
      for (const node of root.querySelectorAll<HTMLElement>("*")) {
        if (node === box) continue;
        const style = getComputedStyle(node);
        if (style.display === "none" || style.visibility === "hidden") continue;
        const rect = node.getBoundingClientRect();
        if (rect.width === 0) continue;
        const sides = [
          ["top", rect.top, style.borderTopWidth, style.borderTopStyle, style.borderTopColor],
          ["bottom", rect.bottom, style.borderBottomWidth, style.borderBottomStyle, style.borderBottomColor],
        ] as const;
        for (const [, y, width, lineStyle, color] of sides) {
          if (!visible(width, lineStyle, color)) continue;
          if (Math.abs(y - boxRect.bottom) > 3 && Math.abs(y - boxRect.top) > 3) continue;
          hairlines.push({ owner: name(node), y, left: rect.left, right: rect.right });
        }
      }

      // A text's ink starts at its first glyph's advance box less the glyph's left side bearing.
      const canvas = document.createElement("canvas").getContext("2d")!;
      const textInk = (node: Element) => {
        const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
          acceptNode: (text) => {
            const parent = text.parentElement;
            if (!text.textContent?.trim() || !parent) return NodeFilter.FILTER_REJECT;
            const style = getComputedStyle(parent);
            if (style.visibility === "hidden" || parent.closest("[hidden],[aria-hidden='true']"))
              return NodeFilter.FILTER_REJECT;
            return parent.getBoundingClientRect().width > 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          },
        });
        const text = walker.nextNode() as Text | null;
        if (!text) throw new Error(`${name(node)} has no visible text`);
        const at = text.textContent!.search(/\S/);
        const range = document.createRange();
        range.setStart(text, at);
        range.setEnd(text, at + 1);
        const style = getComputedStyle(text.parentElement!);
        canvas.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
        return range.getBoundingClientRect().left - canvas.measureText(text.textContent![at]!).actualBoundingBoxLeft;
      };
      // A stroked glyph's ink: its shapes' geometry, widened by half the stroke.
      const glyphInk = (svg: SVGSVGElement) => {
        const scale =
          svg.getBoundingClientRect().width / (svg.viewBox.baseVal?.width || svg.getBoundingClientRect().width);
        let left = Infinity;
        const shapes = "path,circle,rect,line,polyline,polygon,ellipse";
        for (const shape of svg.querySelectorAll<SVGGraphicsElement>(shapes)) {
          const stroke = getComputedStyle(shape).stroke;
          const half = stroke && stroke !== "none" ? (parseFloat(getComputedStyle(shape).strokeWidth) * scale) / 2 : 0;
          left = Math.min(left, shape.getBoundingClientRect().left - half);
        }
        return left;
      };

      const row = box.querySelector(".acpmux-newtab-row")!;
      const centerOf = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return rect.left + rect.width / 2;
      };
      function modeInk(): Lines["mode"] {
        const access = root.querySelector<HTMLElement>(".acpmux-newtab-foot .acpmux-access");
        if (!access || access.getBoundingClientRect().width === 0) return null;
        const svg = [...access.querySelectorAll<SVGSVGElement>("svg")].find((one) => {
          const style = getComputedStyle(one);
          return one.getBoundingClientRect().width > 0 && style.display !== "none" && style.visibility !== "hidden";
        });
        return {
          glyph: svg ? glyphInk(svg) - boxRect.left : null,
          text: textInk(access) - boxRect.left,
          chip: access.getBoundingClientRect().left - boxRect.left,
          center: svg ? centerOf(svg) - boxRect.left : null,
        };
      }
      return {
        box: { left: boxRect.left, right: boxRect.right, top: boxRect.top, bottom: boxRect.bottom, radius },
        hairlines,
        lead: parseFloat(getComputedStyle(root).getPropertyValue("--acpmux-newtab-lead")),
        glyph: glyphInk(row.querySelector<SVGSVGElement>(":scope > svg")!) - boxRect.left,
        allSessions: textInk(root.querySelector(".acpmux-newtab-all")!) - boxRect.left,
        mode: modeInk(),
        glyphCenter: centerOf(row.querySelector(":scope > svg")!) - boxRect.left,
        mark: parseFloat(getComputedStyle(root).getPropertyValue("--acpmux-newtab-mark")),
      };
    });
  }

  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const plainFooter of [false, true])
    for (const width of [680, 1280]) {
      const look = plainFooter ? "plain" : "stepped";
      test(`classic New Tab at ${width}, ${look} footer: no hairline past the box's corners, one left line`, async () => {
        const page = await browser!.newPage({ viewport: { width, height: 700 } });
        try {
          await page.addInitScript(() => {
            const newTab = {
              kind: "agent",
              template: "classic",
              hotkeys: {},
              home: "/Users/you",
              cwd: "/Users/you/src/atlas-web",
              projects: ["/Users/you/src/atlas-web"],
              lastPicks: { global: { harness: "claude", model: "claude-opus-5-5" }, folders: [] },
            };
            localStorage.setItem("cmux.composer.look", "claude");
            Object.assign(window, {
              __cmuxNewTabContext: newTab,
              webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
              cmuxAcpmuxActions: {
                ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
              },
            });
          });
          const { port } = vite!.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}/`);
          await page.locator(".acpmux-newtab .acpmux-composer-foot .acpmux-model .acpmux-picker-button").waitFor();
          await page.evaluate((plainFooter) => window.cmuxAcpmuxComposer?.({ plainFooter }), plainFooter);
          await page.evaluate(() => document.fonts.ready);
          // raf-read: the footer's row fit settles before the following painted frame.
          await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
          const lines = await measure(page);
          console.log(`[new-tab-classic-lines] ${width} ${look}: ${JSON.stringify(lines)}`);

          const { box } = lines;
          for (const line of lines.hairlines) {
            expect({
              ...line,
              insideCorners: line.left >= box.left + box.radius - 0.5 && line.right <= box.right - box.radius + 0.5,
            }).toEqual({
              ...line,
              insideCorners: true,
            });
          }
          // The line is on the 4 px grid (design/grid.md section 1).
          expect(lines.lead % 4).toBe(0);
          expect(Math.abs(lines.allSessions - lines.lead)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(lines.glyph - lines.lead)).toBeLessThanOrEqual(1);
          // The permission mode chip under the box: its shield centers on the row glyph's center line, and
          // whichever ink comes first (the shield, or the label when the look drops it) starts on the lead.
          expect(Math.abs(lines.glyphCenter - lines.mark)).toBeLessThanOrEqual(0.5);
          expect(lines.mode, "the quiet row shows the permission mode").not.toBeNull();
          const mode = lines.mode!;
          expect(Math.abs((mode.center ?? lines.mark) - lines.mark)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(Math.min(mode.glyph ?? Infinity, mode.text) - lines.lead)).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      });
    }
});
