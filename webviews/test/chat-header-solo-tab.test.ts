// A pane with one tab has no tab-row band over its chat (Leo, 2026-11-03: "what if we could? like just... have
// even more of that area be not some row blocking it? cuz isn't it kinda arbitrary anyway if you literally only have
// one tab there?"). The App says so in the `tabRow` event (`soloTab`): the transcript runs up to the pane's top under
// the row, its first message resting where it did below the row, and what scrolls under the tools fades out and
// blurs. The chat's surface runs through the row: no band of another shade. Two or more tabs keep the row as before
// (chat-header-tab-row-surface).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-header-solo-tab.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const read = (file: string) => fs.readFileSync(path.join(source, file), "utf8");
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 2, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const offer = (page: Page, row: { height: number; trailingInset: number; soloTab?: boolean }) =>
    page.evaluate(async (value) => {
      const url = "/header/tabRow.ts";
      const module = (await import(/* @vite-ignore */ url)) as { setTabRow(value: unknown): void };
      module.setTabRow(value);
    }, row);

  const measure = (page: Page) =>
    page.evaluate(() => {
      const scroll = document.querySelector<HTMLElement>(".acpmux-stage > .acpmux-scroll")!;
      const header = document.querySelector<HTMLElement>(".acpmux-stage > .acpmux-header")!;
      const row = document.querySelector<HTMLElement>(".acpmux-scroll .acpmux-row")!;
      return {
        scrollTop: Math.round(scroll.getBoundingClientRect().top),
        headerBottom: Math.round(header.getBoundingClientRect().bottom),
        firstRow: Math.round(row.getBoundingClientRect().top),
        blur: getComputedStyle(header, "::before").backdropFilter,
        solo: document.querySelector(".acpmux-stage")!.hasAttribute("data-solo-tab"),
      };
    });

  test("one tab: the transcript runs up under the row, its first message where it was", async () => {
    const page = await pane.open({ width: 900, height: 640 });
    try {
      await offer(page, { height: 40, trailingInset: 12 });
      await page.waitForFunction(() => document.querySelector(".acpmux-stage > .acpmux-header[data-tab-row]"));
      const shared = await measure(page);
      expect(shared.solo).toBe(false);
      // Two or more tabs: the transcript starts below the row, as before.
      expect(shared.scrollTop).toBe(shared.headerBottom);
      await offer(page, { height: 40, trailingInset: 12, soloTab: true });
      await page.waitForFunction(() => document.querySelector(".acpmux-stage[data-solo-tab]"));
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      const solo = await measure(page);
      // The scroller reaches the pane's top, under the row; the row's header floats over it with a light blur.
      expect(solo.scrollTop).toBe(0);
      expect(solo.headerBottom).toBe(40);
      expect(solo.blur).toContain("blur");
      // The first message rests where it did below the row, not under the tools.
      expect(Math.abs(solo.firstRow - shared.firstRow)).toBeLessThanOrEqual(1);
      expect(solo.firstRow).toBeGreaterThanOrEqual(40);
      // Back to two tabs: the row as before.
      await offer(page, { height: 40, trailingInset: 12, soloTab: false });
      await page.waitForFunction(() => !document.querySelector(".acpmux-stage[data-solo-tab]"));
      expect((await measure(page)).scrollTop).toBe(shared.headerBottom);
    } finally {
      await page.close();
    }
  });

  // The page's own sheets, as the fade test in chat-header-tab-row-surface loads them, in both CI engines: WebKit
  // is the App's. The page's color is red and the rows are black.
  for (const engine of ["chromium", "webkit"] as const) {
    test(`${engine}: a solo row is no band, and text under it fades out and blurs`, async () => {
      const shellCss = [
        read("styles.css"),
        read("agent-session/shared/styles.css"),
        read("agent-session/acpmux/styles.css"),
        read("agent-session/acpmux/header/header.css"),
        read("agent-session/acpmux/conversation/conversation.css"),
      ].join("\n");
      const owned = engine === "webkit" ? await webkit.launch({ headless: true }) : undefined;
      const page = await (owned ?? browser).newPage({ viewport: { width: 320, height: 200 } });
      try {
        const html = (solo: boolean, scrolled: boolean) => `<!doctype html><html><head><style>
          ${shellCss}
          :root { --agent-page-bg: rgb(255, 0, 0); }
          body { margin: 0; height: 200px; }
        </style></head><body>
          <section class="acpmux-shell" data-tab-row ${solo ? "data-solo-tab" : ""} style="--acpmux-tab-row-height:40px;height:200px">
            <div class="acpmux-stage" ${solo ? "data-solo-tab" : ""} style="flex:1;display:flex;flex-direction:column;min-height:0">
              <header class="acpmux-header" data-tab-row></header>
              <div class="acpmux-scroll" ${scrolled ? "data-fade-top" : ""} style="flex:1;min-height:0;overflow:hidden">
                <div style="height:${scrolled ? 0 : 56}px"></div>
                <div style="height:400px;background:rgb(0,0,0)"></div>
              </div>
            </div>
          </section>
        </body></html>`;
        const shot = async (solo: boolean, scrolled: boolean) => {
          await page.setContent(html(solo, scrolled));
          const { PNG } = await import("pngjs");
          const png = PNG.sync.read(await page.screenshot({ type: "png", omitBackground: true }));
          return (y: number) =>
            [png.data[(png.width * y + 150) * 4]!, png.data[(png.width * y + 150) * 4 + 3]!] as const;
        };
        // Two or more tabs: the row is the window's, a band of another shade over the chat.
        const shared = await shot(false, false);
        expect(shared(20)[1]).toBe(0);
        // One tab, at rest: the chat's surface runs through the row, the same as just below it.
        const rest = await shot(true, false);
        expect(rest(4)).toEqual([255, 255]);
        expect(rest(30)).toEqual([255, 255]);
        expect(rest(50)).toEqual([255, 255]);
        expect(rest(100)[0]).toBe(0);
        // Scrolled, the rows run to the top under the row: faint at its top, stronger toward its foot, full ink below.
        const scrolled = await shot(true, true);
        expect(scrolled(1)[0]).toBeGreaterThan(200);
        expect(scrolled(30)[0]).toBeLessThan(scrolled(4)[0]);
        expect(scrolled(60)[0]).toBe(0);
        // The light blur sits under the tools.
        const blur = await page
          .locator(".acpmux-header")
          .evaluate(
            (node) =>
              getComputedStyle(node, "::before").getPropertyValue("backdrop-filter") ||
              getComputedStyle(node, "::before").getPropertyValue("-webkit-backdrop-filter"),
          );
        expect(blur).toContain("blur");
      } finally {
        await page.close();
        await owned?.close();
      }
    });
  }

  // A line under the header (a live chat's choice, a watched chat with `data-enter="top"`; a Create Checkpoint review,
  // which has none) keeps the transcript below it: the transcript never covers its buttons or takes their clicks.
  for (const line of [
    `<div class="acpmux-link-missing" data-enter="top" style="height:30px"><button id="act">Take over</button></div>`,
    `<section class="acpmux-checkpoint-review" style="height:30px"><button id="act">Create</button></section>`,
  ]) {
    test(`a line under the header keeps the transcript below it in a solo row: ${line.slice(1, 40)}`, async () => {
      const shellCss = [
        read("styles.css"),
        read("agent-session/shared/styles.css"),
        read("agent-session/acpmux/styles.css"),
        read("agent-session/acpmux/header/header.css"),
        read("agent-session/acpmux/conversation/conversation.css"),
      ].join("\n");
      const page = await browser.newPage({ viewport: { width: 320, height: 200 } });
      try {
        await page.setContent(`<!doctype html><html><head><style>${shellCss} body{margin:0;height:200px}</style></head><body>
          <section class="acpmux-shell" data-tab-row data-solo-tab style="--acpmux-tab-row-height:40px;height:200px">
            <div class="acpmux-stage" data-solo-tab style="flex:1;display:flex;flex-direction:column;min-height:0">
              <header class="acpmux-header" data-tab-row></header>
              ${line}
              <div class="acpmux-scroll" style="flex:1;min-height:0;position:relative;z-index:1;background:#000"></div>
            </div>
          </section></body></html>`);
        const box = await page.evaluate(() => {
          const button = document.querySelector<HTMLElement>("#act")!.getBoundingClientRect();
          return {
            line: Math.round(document.querySelector("#act")!.parentElement!.getBoundingClientRect().bottom),
            scroll: Math.round(document.querySelector(".acpmux-scroll")!.getBoundingClientRect().top),
            hit: document.elementFromPoint(button.left + 2, button.top + button.height / 2)?.id,
          };
        });
        expect(box.scroll).toBeGreaterThanOrEqual(box.line);
        expect(box.hit).toBe("act");
      } finally {
        await page.close();
      }
    });
  }

  test("the App tells the page the pane holds one tab, and only the chat's own stage takes it", () => {
    const app = read("agent-session/acpmux/App.tsx");
    expect(app).toContain("const soloTab = inTabRow && tabRow.soloTab === true;");
    expect(app).toContain("topInset={soloUnder ? tabRow.height : 0}");
  });
});
