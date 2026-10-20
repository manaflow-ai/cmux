// cmux-web-test-timeout: 300
// Claude Code's composer split (Leo 2026-10-19: "just follow how Claude Code does these", "stick it
// to the bottom"), in the chat composer and the New Tab page alike (ComposerFoot.tsx):
//
// - The box keeps +, the prompt, the mic and Send or Stop. The mode, model and effort sit in a quiet
//   row under the box: the mode on the left, on the prompt's text edge; the model and effort on the
//   right, their labels about 8 px apart (Claude Code's spacing).
// - The mic never leaves, at a roomy width or a narrow one.
// - + is its glyph, named "Add" by the shared tooltip.
// - The mode menu marks the chosen mode with a check at the row's trailing edge, where the other
//   rows show their number, as Claude's model menu does.
// - The + menu's and the @ file picker's rows highlight under the pointer, one row at a time.
//
// Real Chromium and WebKit on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-claude-split.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-claude-split.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-claude-split: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer claude split", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}&frame=component&width=${width}&theme=Catppuccin+Mocha`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    for (const [name, engine] of engines) {
      const browser = await engine.launch({ headless: true });
      browsers.set(name, browser);
      const warm = await browser.newPage({ viewport: { width: 760, height: 600 } });
      await warm.goto(stageURL("agent-pane.new-tab", "reasoning-chip", 760));
      for (;;) {
        try {
          await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      await warm.close();
    }
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Stage = { name: string; entry: string; variant: string; composer: string; box: string; plus: boolean };
  const COMPOSERS: Stage[] = [
    {
      name: "chat composer",
      entry: "agent-pane.composer",
      variant: "quiet-chips",
      composer: ".acpmux-composer",
      box: ".acpmux-composer-box",
      plus: true,
    },
    {
      name: "New Tab composer",
      entry: "agent-pane.new-tab",
      // The Default template (composer-mic pins it): Cards draws its chips and mic under the pill.
      variant: "composer-mic",
      composer: ".nt-composer",
      box: ".nt-box",
      // The New Tab page has no + button (it takes pastes and drops): its box has no +.
      plus: false,
    },
  ];

  const open = async (engine: string, stage: Stage, width = 760) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await page.waitForTimeout(200);
    return page;
  };

  type Rect = { left: number; right: number; top: number; bottom: number; width: number };
  /** Where the composer's parts draw. */
  const layout = (page: Page, stage: Stage) =>
    page.evaluate(
      ({ composer, box }) => {
        const root = document.querySelector<HTMLElement>(composer)!;
        const card = root.querySelector<HTMLElement>(box)!;
        const rect = (element: Element | null): Rect | null => {
          if (!element) return null;
          const r = element.getBoundingClientRect();
          if (r.width === 0 || getComputedStyle(element).visibility === "hidden") return null;
          return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width };
        };
        const text = (element: Element | null): Rect | null => {
          if (!element) return null;
          const range = document.createRange();
          range.selectNodeContents(element);
          const r = range.getBoundingClientRect();
          return r.width ? { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width } : null;
        };
        const foot = root.querySelector(".acpmux-composer-foot");
        return {
          box: rect(card)!,
          foot: rect(foot),
          inBox: {
            model: !!card.querySelector(".acpmux-model"),
            effort: !!card.querySelector(".acpmux-effort"),
            mode: !!card.querySelector(".acpmux-access"),
          },
          mode: text(root.querySelector(".acpmux-composer-foot .acpmux-mode-text")),
          model: text(root.querySelector(".acpmux-composer-foot .acpmux-model .acpmux-picker-button > span")),
          effort: text(root.querySelector(".acpmux-composer-foot .acpmux-effort [data-fit-part='effort']")),
          modelButton: rect(root.querySelector(".acpmux-composer-foot .acpmux-model .acpmux-picker-button")),
          effortButton: rect(root.querySelector(".acpmux-composer-foot .acpmux-effort .acpmux-picker-button")),
          ring: rect(root.querySelector(".acpmux-composer-foot .acpmux-context-ring")),
          // The row's rightmost control: the context ring once the chat reports usage, else effort.
          end: Math.max(
            ...[...root.querySelectorAll(".acpmux-composer-foot button")].map(
              (button) => button.getBoundingClientRect().right,
            ),
          ),
          prompt: text(
            card.querySelector(".nt-field, .acpmux-md")?.closest(".nt-input, .acpmux-composer-prompt") ?? null,
          ),
          mic: rect(card.querySelector(".acpmux-mic")),
          send: rect(card.querySelector(".acpmux-send")),
          plus: rect(card.querySelector(".acpmux-composer-plus .acpmux-picker-button")),
        };
      },
      { composer: stage.composer, box: stage.box },
    );

  for (const [engine] of engines) {
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: the box keeps the prompt, mic and Send; mode, model and effort sit in the quiet row under it`, async () => {
        const page = await open(engine, stage);
        const at = await layout(page, stage);
        await page.close();
        expect(at.inBox, "no chip in the box").toEqual({ model: false, effort: false, mode: false });
        expect(at.foot, "the quiet row draws").not.toBeNull();
        expect(at.foot!.top, "the row is under the box").toBeGreaterThanOrEqual(at.box.bottom - 0.5);
        expect(at.foot!.top - at.box.bottom, "a few px under it").toBeLessThanOrEqual(8);
        expect(at.mic, "the mic is in the box").not.toBeNull();
        expect(at.send, "Send is in the box").not.toBeNull();
        if (stage.plus) expect(at.plus, "+ is in the box").not.toBeNull();
        // The mode on the left, on the prompt's text edge (16 px in from the box, Claude Code's). A
        // New Tab page before its chat starts may have no mode yet; the model and effort stay right.
        if (stage.plus) expect(at.mode, "the mode names itself").not.toBeNull();
        if (at.mode) {
          expect(Math.abs(at.mode.left - (at.box.left + 16)), "the mode's text on the 16 px edge").toBeLessThanOrEqual(
            3,
          );
          expect(at.model!.left, "the model is right of the mode").toBeGreaterThan(at.mode.right + 40);
        }
        expect(at.model!.left, "the model sits in the row's right half").toBeGreaterThan(
          at.box.left + at.box.width / 2,
        );
        // The model and effort chips side by side (each chip's 4 px hover inset is their spacing).
        expect(
          Math.abs(at.effortButton!.left - at.modelButton!.right),
          "model and effort chips touch",
        ).toBeLessThanOrEqual(2);
        expect(at.box.right - at.end, "the row ends near the box's right side").toBeLessThanOrEqual(14);
        // Claude Code ends the row on the context ring, right of effort, once there is usage.
        // The chat's ring keeps its place from the start; the New Tab page has no chat yet, so no ring.
        expect(Boolean(at.ring), "the chat's quiet row ends on the context ring").toBe(stage.plus);
        if (at.ring)
          expect(at.ring.left, "the ring follows effort").toBeGreaterThanOrEqual(at.effortButton!.right - 0.5);
      });

    for (const stage of COMPOSERS)
      for (const width of [760, 300])
        test(`${engine}: ${stage.name} at ${width} px: the mic stays`, async () => {
          const page = await open(engine, stage, width);
          const at = await layout(page, stage);
          await page.close();
          expect(at.mic, "the mic shows").not.toBeNull();
          expect(at.mic!.width, "the mic at full size").toBeGreaterThanOrEqual(20);
          expect(at.send!.left, "Send after the mic").toBeGreaterThanOrEqual(at.mic!.right - 0.5);
          expect(at.send!.right, "Send inside the box").toBeLessThanOrEqual(at.box.right);
        });

    test(`${engine}: + is its glyph, named Add by the shared tooltip`, async () => {
      const page = await open(engine, COMPOSERS[0]!);
      const plus = await page
        .locator(".acpmux-composer-plus .acpmux-picker-button")
        .first()
        .evaluate((element) => ({
          text: element.textContent?.trim() ?? "",
          tooltip: element.getAttribute("data-tooltip") ?? element.getAttribute("title") ?? "",
        }));
      await page.close();
      expect(plus).toEqual({ text: "", tooltip: "Add" });
    });

    // The New Tab stage has no chat yet, so no mode menu; both pages draw the same AccessMenu.
    for (const stage of COMPOSERS.filter((stage) => stage.plus))
      test(`${engine}: ${stage.name}: the mode menu checks the chosen mode at the trailing edge, in its number's place`, async () => {
        const page = await open(engine, stage);
        await page.locator(`${stage.composer} .acpmux-access .acpmux-picker-button`).first().click();
        await page.locator(".acpmux-access-item").first().waitFor();
        const rows = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-access-item")].map((row) => {
            const box = (selector: string) => {
              const element = row.querySelector<HTMLElement>(selector);
              if (!element || getComputedStyle(element).visibility === "hidden") return null;
              const r = element.getBoundingClientRect();
              return r.width ? { left: r.left, right: r.right } : null;
            };
            const check = row.querySelector(".ui-menu-check")?.textContent?.trim() ?? "";
            return {
              checked: row.hasAttribute("data-checked"),
              check: check ? box(".ui-menu-check") : null,
              number: box(".ui-menu-shortcut"),
              label: box(".acpmux-menu-label")!,
              right: row.getBoundingClientRect().right,
            };
          }),
        );
        await page.close();
        const chosen = rows.filter((row) => row.checked);
        expect(chosen.length, "one mode is chosen").toBe(1);
        const row = chosen[0]!;
        expect(row.check, "the chosen row draws its check").not.toBeNull();
        expect(row.check!.left, "the check is after the label").toBeGreaterThan(row.label.right);
        expect(row.right - row.check!.right, "the check sits at the trailing edge").toBeLessThanOrEqual(16);
        expect(row.number, "its number gives way to the check").toBeNull();
        for (const other of rows.filter((row) => !row.checked)) {
          expect(other.number, "another row shows its number").not.toBeNull();
          expect(
            Math.abs(other.number!.right - row.check!.right),
            "number and check share a column",
          ).toBeLessThanOrEqual(6);
        }
      });

    // The + menu's rows (Attach, @ mention...) and the @ picker's files answer the pointer.
    test(`${engine}: the + menu and the @ file picker highlight the row under the pointer, one at a time`, async () => {
      const page = await open(engine, COMPOSERS[0]!);
      const highlighted = (selector: string) =>
        page.evaluate(
          (selector) =>
            [...document.querySelectorAll<HTMLElement>(selector)].map((row) => {
              const fill = getComputedStyle(row).backgroundColor;
              return fill !== "rgba(0, 0, 0, 0)" && fill !== "transparent";
            }),
          selector,
        );
      await page.locator(".acpmux-composer-plus .acpmux-picker-button").first().click();
      const rows = page.locator(".acpmux-menu .acpmux-menu-item");
      await rows.first().waitFor();
      const count = await rows.count();
      expect(count, "the + menu lists its actions").toBeGreaterThan(1);
      const last = (await rows.nth(count - 1).boundingBox())!;
      await page.mouse.move(last.x + last.width / 2, last.y + last.height / 2);
      await page.waitForTimeout(200);
      const plusRows = await highlighted(".acpmux-menu .acpmux-menu-item");
      expect(plusRows.filter(Boolean).length, "one + row is lit").toBe(1);
      expect(plusRows[count - 1], "the row under the pointer").toBe(true);
      await page.keyboard.press("Escape");

      await page.locator(".acpmux-composer-box .acpmux-md").first().click();
      await page.keyboard.type("@");
      const files = page.locator(".acpmux-mention-row");
      const listed = await files
        .first()
        .waitFor({ timeout: 5_000 })
        .then(() => true)
        .catch(() => false);
      if (listed && (await files.count()) > 1) {
        const second = (await files.nth(1).boundingBox())!;
        await page.mouse.move(second.x + second.width / 2, second.y + second.height / 2);
        await page.waitForTimeout(200);
        const fileRows = await highlighted(".acpmux-mention-row");
        expect(fileRows.filter(Boolean).length, "one file row is lit").toBe(1);
        expect(fileRows[1], "the file under the pointer").toBe(true);
      }
      await page.close();
    });
  }
});
