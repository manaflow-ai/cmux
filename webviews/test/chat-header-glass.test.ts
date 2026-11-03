// The header tools' glass in a one-tab pane (Leo, 2026-11-03: "surely we can do a nice and unobtrusive apple glass type
// thing that's super subtle until there's text or something beneath right ... if u just look at how chatgpt ios does
// things"). One capsule of glass behind the tools: not there at rest (no fill at rest, design/chat-header.md), faded
// in once rows scroll under the row, where it dims and frosts the words under the tools. It never moves a tool, and it
// is the solo row's only: two or more tabs keep the plain row. Both CI engines: WebKit is the App's.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-header-glass.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const read = (file: string) => fs.readFileSync(path.join(source, file), "utf8");
  const sheets = () =>
    [
      read("pages/shared/desktop.css"),
      read("ui/glass/glass.css"),
      read("agent-session/shared/styles.css"),
      read("agent-session/acpmux/styles.css"),
      read("agent-session/acpmux/header/header.css"),
      read("agent-session/acpmux/conversation/conversation.css"),
    ].join("\n");
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // A white surface, black rows under the row when scrolled, and four 24px tools at the row's right (the ⋮ last, 16px).
  const html = (css: string, solo: boolean, scrolled: boolean) => `<!doctype html><html><head><style>
    ${css}
    :root { --cmux-surface-solid: rgb(255, 255, 255); --agent-text: rgb(0, 0, 0); }
    body { margin: 0; height: 200px; }
    .acpmux-header-tool { color: transparent !important; }
  </style></head><body>
    <section class="acpmux-shell" data-tab-row ${solo ? "data-solo-tab" : ""} style="--acpmux-tab-row-height:40px;--acpmux-tab-row-inset:0px;height:200px;display:flex;flex-direction:column">
      <div class="acpmux-stage" ${solo ? "data-solo-tab" : ""} style="flex:1;display:flex;flex-direction:column;min-height:0">
        <header class="acpmux-header" data-tab-row style="display:flex;align-items:center;justify-content:flex-end">
          <div class="acpmux-handoff-header-tools" style="display:flex">
            <div class="acpmux-header-tools">
              <button class="acpmux-header-tool"></button><button class="acpmux-header-tool"></button>
              <button class="acpmux-header-tool"></button><button class="acpmux-header-tool acpmux-header-more"></button>
            </div>
          </div>
        </header>
        <div class="acpmux-scroll" ${scrolled ? "data-fade-top" : ""} style="flex:1;min-height:0;overflow:hidden">
          <div style="height:${scrolled ? 0 : 56}px"></div>
          <div style="height:400px;background:rgb(0,0,0)"></div>
        </div>
      </div>
    </section>
  </body></html>`;

  for (const engine of ["chromium", "webkit"] as const) {
    test(`${engine}: the capsule is absent at rest, fades in over text, dims it and moves nothing`, async () => {
      const css = sheets();
      const owned = engine === "webkit" ? await webkit.launch({ headless: true }) : undefined;
      const page = await (owned ?? browser).newPage({ viewport: { width: 320, height: 200 } });
      // No fade to wait out.
      await page.emulateMedia({ reducedMotion: "reduce" });
      try {
        const state = async (solo: boolean, scrolled: boolean, extra = "") => {
          await page.setContent(html(css + extra, solo, scrolled));
          return page.evaluate(() => {
            const tools = document.querySelector<HTMLElement>(".acpmux-header-tools")!;
            const glass = getComputedStyle(tools, "::before");
            const box = tools.getBoundingClientRect();
            const first = tools.querySelector<HTMLElement>(".acpmux-header-tool")!.getBoundingClientRect();
            return {
              opacity: Number(glass.opacity),
              content: glass.content,
              radius: parseFloat(glass.borderTopLeftRadius),
              backdrop: glass.backdropFilter || glass.getPropertyValue("-webkit-backdrop-filter"),
              box: [box.left, box.top, box.width, box.height].map(Math.round),
              first: [first.left, first.top].map(Math.round),
            };
          });
        };
        // At rest nothing is under the row: no capsule, the tools are plain glyphs.
        const rest = await state(true, false);
        expect(rest.opacity).toBe(0);
        // Scrolled: one round capsule of frosted glass behind the tools.
        const over = await state(true, true);
        expect(over.opacity).toBe(1);
        expect(over.radius).toBeGreaterThanOrEqual(15);
        expect(over.backdrop).toContain("blur");
        // It is drawn behind them: no tool moves and the group keeps its box.
        expect(over.box).toEqual(rest.box);
        expect(over.first).toEqual(rest.first);
        // Two or more tabs: the transcript stays below the row, so the row never takes the glass.
        expect((await state(false, true)).opacity).toBe(0);

        // Pixels: the row's foot between two tools, over black rows. The capsule lifts it toward the white surface.
        const foot = async (extra = "") => {
          await page.setContent(html(css + extra, true, true));
          const at = await page.evaluate(() => {
            const buttons = [...document.querySelectorAll<HTMLElement>(".acpmux-header-tool")];
            const a = buttons[1]!.getBoundingClientRect();
            return { x: Math.round(a.right + 1), y: Math.round(a.bottom - 2) };
          });
          const { PNG } = await import("pngjs");
          const png = PNG.sync.read(await page.screenshot({ type: "png" }));
          return png.data[(png.width * at.y + at.x) * 4]!;
        };
        const none = await foot(".acpmux-header-tools::before{content:none !important}");
        const glass = await foot();
        expect(glass - none).toBeGreaterThan(40);
      } finally {
        await page.close();
        await owned?.close();
      }
    });
  }
});
