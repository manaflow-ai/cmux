// cmux-web-test-timeout: 300
// Claude Code's composer split (Leo 2026-10-19: "just follow how Claude Code does these", "stick it
// to the bottom"), in the chat composer and the New Tab page alike (ComposerFoot.tsx):
//
// - The box keeps +, the prompt, the mic and Send or Stop. The mode and one model button sit in a
//   quiet row under the box: the mode on the left, on the prompt's text edge; on the right the model
//   button, which names the model and then its effort ("Opus 5.5  Medium", Leo 2026-10-20: one
//   button, no effort chip of its own), then the chat's context ring.
// - The chat's Send comes in after the mic with a draft; an empty chat draft draws the mic alone
//   (Claude desktop's box: no Send until there is a draft, Leo 2026-10-20). The New Tab page keeps Send.
// - The mic never leaves, at a roomy width or a narrow one.
// - + is its glyph, named "Add" for screen readers, with Codex's short tooltip "Add files and more"
//   (Leo, 2026-10-21; it overrides 2026-10-20's "a plain + needs none").
// - The mode menu marks the chosen mode with a check at the row's trailing edge, where the other
//   rows show their number, as Claude's model menu does.
// - The + menu's and the @ file picker's rows highlight under the pointer, one row at a time.
//
// Real Chromium and WebKit on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-claude-split.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "reasoning-chip" } });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Stage = {
    name: string;
    entry: string;
    variant: string;
    composer: string;
    box: string;
    plus: boolean;
    /** Whether Send draws with an empty draft (the chat's waits for a draft; the New Tab page's always draws). */
    sendAtRest: boolean;
  };
  const COMPOSERS: Stage[] = [
    {
      name: "chat composer",
      entry: "agent-pane.composer",
      variant: "quiet-chips",
      composer: ".acpmux-composer",
      box: ".acpmux-composer-box",
      plus: true,
      sendAtRest: false,
    },
    {
      name: "New Tab composer",
      entry: "agent-pane.new-tab",
      // Cards (composer-mic pins it), the first dot, draws the split; Default keeps its chips in the box.
      variant: "composer-mic",
      composer: ".nt-composer",
      box: ".nt-box",
      // The New Tab page has no + button (it takes pastes and drops): its box has no +.
      plus: false,
      sendAtRest: true,
    },
  ];

  /** Resolves once nothing on the page is easing: no transition or animation left to run (a
   *  looping one never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  /** Resolves once the pointer is over the `index`th element `selector` matches, as the page sees it,
   *  and its highlight has eased in. */
  const pointedAt = async (page: Page, selector: string, index: number) => {
    await page.waitForFunction(
      ([selector, index]) => document.querySelectorAll(selector)[index]?.matches(":hover") === true,
      [selector, index] as const,
    );
    await eased(page);
  };

  const open = async (engine: string, stage: Stage, width = 760) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await eased(page);
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
            effort: !!card.querySelector(".acpmux-effort, .acpmux-model-detail"),
            mode: !!card.querySelector(".acpmux-access"),
          },
          mode: text(root.querySelector(".acpmux-composer-foot .acpmux-mode-text")),
          // The mode button leads with its symbol, then its name (Leo 2026-10-21: Codex's "(!) Full access").
          modeSymbol: rect(root.querySelector(".acpmux-composer-foot .acpmux-access-trigger > svg:first-child")),
          model: text(root.querySelector(".acpmux-composer-foot .acpmux-model .acpmux-picker-button > span")),
          effort: text(
            root.querySelector(
              ".acpmux-composer-foot .acpmux-model .acpmux-model-detail[data-fit-forms~='full']:not(.acpmux-fit-label)",
            ),
          ),
          modelButton: rect(root.querySelector(".acpmux-composer-foot .acpmux-model .acpmux-picker-button")),
          // An effort chip of its own is gone since Leo 2026-10-20.
          effortChip: !!root.querySelector(".acpmux-composer-foot .acpmux-effort"),
          ring: rect(root.querySelector(".acpmux-composer-foot .acpmux-context-ring")),
          // The row's rightmost control: the context ring once the chat reports usage, else the model.
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
      test(`${engine}: ${stage.name}: the box keeps the prompt, mic and Send; the mode and the model button sit in the quiet row under it`, async () => {
        const page = await open(engine, stage);
        const at = await layout(page, stage);
        await page.close();
        expect(at.inBox, "no chip in the box").toEqual({ model: false, effort: false, mode: false });
        expect(at.foot, "the quiet row draws").not.toBeNull();
        expect(at.foot!.top, "the row is under the box").toBeGreaterThanOrEqual(at.box.bottom - 0.5);
        expect(at.foot!.top - at.box.bottom, "a few px under it").toBeLessThanOrEqual(8);
        expect(at.mic, "the mic is in the box").not.toBeNull();
        if (stage.sendAtRest) expect(at.send, "Send is in the box").not.toBeNull();
        else expect(at.send, "no Send with an empty draft").toBeNull();
        if (stage.plus) expect(at.plus, "+ is in the box").not.toBeNull();
        // The harness is selected from the model picker rail. The quiet row starts with Access,
        // then the model button, and keeps the context ring at the trailing edge.
        if (stage.plus) expect(at.mode, "the mode names itself").not.toBeNull();
        if (at.mode) {
          expect(at.modeSymbol, "the mode draws its symbol").not.toBeNull();
          expect(at.mode.left, "the mode's name follows its symbol").toBeGreaterThan(at.modeSymbol!.right);
          expect(at.model!.left, "the model is right of the mode").toBeGreaterThan(at.mode.right);
        }
        expect(at.model!.left, "the model sits in the row's right half").toBeGreaterThan(
          at.box.left + at.box.width / 2,
        );
        // One button: the effort follows the model's name inside it, never a chip of its own.
        expect(at.effortChip, "no effort chip of its own").toBe(false);
        expect(at.effort, "the model button names its effort").not.toBeNull();
        expect(at.effort!.left, "the effort follows the model's name").toBeGreaterThan(at.model!.right);
        expect(at.effort!.right, "the effort is inside the model button").toBeLessThanOrEqual(
          at.modelButton!.right + 0.5,
        );
        expect(at.box.right - at.end, "the row ends near the box's right side").toBeLessThanOrEqual(14);
        // Claude Code ends the row on the context ring, right of the model button, once there is usage.
        // The chat's ring keeps its place from the start; the New Tab page has no chat yet, so no ring.
        expect(Boolean(at.ring), "the chat's quiet row ends on the context ring").toBe(stage.plus);
        if (at.ring)
          expect(at.ring.left, "the ring follows the model button").toBeGreaterThanOrEqual(at.modelButton!.right - 0.5);
      });

    for (const stage of COMPOSERS)
      for (const width of [760, 300])
        test(`${engine}: ${stage.name} at ${width} px: the mic stays`, async () => {
          const page = await open(engine, stage, width);
          // The chat's Send waits for a draft: type one so Send comes in. In the chat it takes the one
          // send slot before the mic, Claude desktop's ↵ (Leo 2026-10-31: "THE F***ING TWO SEND
          // BUTTONS"), so the mic keeps the right edge; New Tab's Send stays after the mic.
          if (!stage.sendAtRest) {
            await page.locator(`${stage.box} .acpmux-md`).first().click();
            await page.keyboard.type("Retry");
            await page.locator(`${stage.box} .acpmux-send`).waitFor();
          }
          const at = await layout(page, stage);
          await page.close();
          expect(at.mic, "the mic shows").not.toBeNull();
          expect(at.mic!.width, "the mic at full size").toBeGreaterThanOrEqual(20);
          if (stage.sendAtRest) expect(at.send!.left, "Send after the mic").toBeGreaterThanOrEqual(at.mic!.right - 0.5);
          else expect(at.send!.right, "Send before the mic").toBeLessThanOrEqual(at.mic!.left + 0.5);
          expect(at.send!.left, "Send inside the box").toBeGreaterThanOrEqual(at.box.left);
          expect(at.mic!.right, "the mic inside the box").toBeLessThanOrEqual(at.box.right);
        });

    test(`${engine}: + is its glyph, named Add, its tooltip "Add files and more"`, async () => {
      const page = await open(engine, COMPOSERS[0]!);
      const plus = await page
        .locator(".acpmux-composer-plus .acpmux-picker-button")
        .first()
        .evaluate((element) => ({
          text: element.textContent?.trim() ?? "",
          name: element.getAttribute("aria-label") ?? "",
          tooltip: element.getAttribute("data-tooltip") ?? element.getAttribute("title") ?? "",
        }));
      await page.close();
      expect(plus).toEqual({ text: "", name: "Add", tooltip: "Add files and more" });
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
      await pointedAt(page, ".acpmux-menu .acpmux-menu-item", count - 1);
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
        await pointedAt(page, ".acpmux-mention-row", 1);
        const fileRows = await highlighted(".acpmux-mention-row");
        expect(fileRows.filter(Boolean).length, "one file row is lit").toBe(1);
        expect(fileRows[1], "the file under the pointer").toBe(true);
      }
      await page.close();
    });
  }
});
