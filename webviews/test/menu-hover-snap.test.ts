// cmux-web-test-timeout: 180
// Lawrence 2026-11-17 (screen recording of a new chat's composer, its folder chip "fun" and its
// location chip "Cloud · cmux-lab"): "fix these hover bugs".
//
// 1. Two menu rows lit at once. A row's highlight came on in the frame the pointer reached it
//    (pages/shared/desktop.css) but the row it left faded out over the row's 80 ms background
//    transition, so a move from This Mac to Other devices showed two or three lit rows for ~130 ms,
//    and "No folder" stayed lit after the pointer had left the menu. A menu's highlight moves as an
//    NSMenu's does: the row the pointer leaves clears in the frame the next one lights.
// 2. The open chip lost its pill under the pointer. The location strip's hover rule
//    (`.acpmux-location-button.ui-ghost:hover { background: transparent }`) outranked the open
//    state, so an open chip's pill went away whenever the pointer crossed it and came back when it
//    left: a flicker. An open chip keeps its pill, pointer over it or not.
//
// The page is the real stylesheets in a real engine (as test/hover-row-sweep.test.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { MOTION_MS } from "../src/motion/scale.generated";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("menu-hover-snap.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const sheet = (...files: string[]) =>
    files
      .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
      .join("\n")
      .replace(/^@import .*$/gm, "");
  const css = sheet(
    "pages/shared/desktop.css",
    "ui/ui.css",
    "ui/ghost.css",
    "agent-session/acpmux/composerStates.css",
    "agent-session/acpmux/composerLocation.css",
  );

  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 600, height: 400 } });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const LIT = "rgb(200, 200, 200)";
  const CLEAR = "rgba(0, 0, 0, 0)";

  async function mount(body: string) {
    await page.setContent(
      `<!doctype html><html><head><style>${css}
      :root { --agent-motion-hover: ${MOTION_MS.quick}ms; --acpmux-motion-hover: ${MOTION_MS.quick}ms; --cmux-motion-quick: ${MOTION_MS.quick}ms;
        --acpmux-menu-hover: ${LIT}; --acpmux-composer-hover: rgb(90, 90, 90); --agent-text: #000; --agent-muted: #444; }
      body { margin: 0; background: #fff; color: #000; }
      .row { display: block; height: 28px; width: 300px; }
      </style></head><body>${body}</body></html>`,
    );
  }

  /// Moves the highlight from `from` to `to` as Base UI does (one task), then reads every row's fill
  /// in each of the next painted frames.
  async function moveHighlight(from: number, to: number) {
    return page.evaluate(
      async ([a, b]) => {
        const rows = [...document.querySelectorAll<HTMLElement>(".row")];
        rows[a]!.removeAttribute("data-highlighted");
        rows[b]!.setAttribute("data-highlighted", "");
        const frames: string[][] = [];
        for (let i = 0; i < 4; i++) {
          await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
          frames.push(rows.map((row) => getComputedStyle(row).backgroundColor));
        }
        return frames;
      },
      [from, to] as const,
    );
  }

  const menu = (cls: string) =>
    `<div class="ui-popup acpmux-menu acpmux-location-menu acpmux-folder-popover acpmux-env-popover">
      ${[0, 1, 2].map((i) => `<div role="option" class="${cls} row" id="r${i}">Row ${i}</div>`).join("")}
    </div>`;

  for (const [name, cls] of [
    ["environment menu (combobox rows)", "ui-combobox-item acpmux-menu-item"],
    ["folder menu (combobox rows)", "ui-combobox-item acpmux-menu-item rounded-lg"],
  ] as const) {
    test(`${name}: the row the highlight leaves clears in the frame the next lights`, async () => {
      await mount(menu(cls));
      await page.evaluate(() => document.getElementById("r0")!.setAttribute("data-highlighted", ""));
      await page.waitForFunction(() => document.getAnimations().length === 0, undefined, { polling: "raf" });
      const frames = await moveHighlight(0, 2);
      // Every frame after the move: row 2 lit, rows 0 and 1 clear. Never two rows lit at once.
      for (const frame of frames) expect(frame).toEqual([CLEAR, CLEAR, LIT]);
    });
  }

  test("an open location chip keeps its pill while the pointer is over it", async () => {
    await mount(
      `<div class="acpmux-composer-context" style="padding:40px">
        <button type="button" class="ui-ghost acpmux-location-button" aria-expanded="true" data-popup-open id="chip"
          style="display:inline-flex;height:22px;padding:0 8px">fun</button>
      </div>`,
    );
    const away = await page.$eval("#chip", (chip) => getComputedStyle(chip).backgroundColor);
    expect(away).toBe("rgb(90, 90, 90)");
    const box = (await page.locator("#chip").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.waitForFunction(
      () => document.getElementById("chip")!.matches(":hover") && document.getAnimations().length === 0,
      undefined,
      { polling: "raf" },
    );
    const over = await page.$eval("#chip", (chip) => getComputedStyle(chip).backgroundColor);
    expect(over).toBe(away);
  });

  test("a closed location chip still draws no pill on hover", async () => {
    await mount(
      `<div class="acpmux-composer-context" style="padding:40px">
        <button type="button" class="ui-ghost acpmux-location-button" aria-expanded="false" id="chip"
          style="display:inline-flex;height:22px;padding:0 8px">fun</button>
      </div>`,
    );
    const box = (await page.locator("#chip").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.waitForFunction(
      () => document.getElementById("chip")!.matches(":hover") && document.getAnimations().length === 0,
      undefined,
      { polling: "raf" },
    );
    expect(await page.$eval("#chip", (chip) => getComputedStyle(chip).backgroundColor)).toBe(CLEAR);
  });
});
