// l10n-allow-file: browser fixture prompts, not shipped UI.
// The caret beside a pasted workspace link's chip in the composer is painted, at the line's height,
// before and after the chip, and the chip stays a chip when text is typed or another link pasted
// right after it (Leo, 2026-11-09: "when I do these links that I copy, the caret sort of disappears
// on it, and then after I paste in another thing, it just becomes unformatted again ... it's just
// weird that it doesn't have a caret"). The link's characters had been drawn at no size under the
// chip, and the caret at the link's end was drawn there, at no height. Measured on the painted
// caret (drawn magenta, found in screenshots) in both of the lane's engines (WebKit is the app's).
// The composer takes a real click and real typing while a Cloud start is out (Leo: "I can't click
// into the composer at all").
// cmux-web-test-timeout: 600
import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-chip-caret.browser.test.ts", async () => {
  setDefaultTimeout(600_000);

  const ENTRY = "agent-pane.composer-chip-caret";
  const WORKSPACE = "cmux-nightly://workspace/ws_a21d11e10694e6e0fbf7ea446075f32c";
  const CARET = { r: 255, g: 0, b: 255 };
  const WIDTH = 900;

  type Box = { left: number; right: number; top: number; bottom: number };

  const nextFrames = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done) => {
          let left = 4;
          // raf-read: reads nothing; it only lets four frames pass before the next screenshot.
          const tick = () => (--left ? requestAnimationFrame(tick) : done());
          requestAnimationFrame(tick);
        }),
    );

  /// The painted caret's box (CSS px) inside `band`, read from screenshots until a blink shows it at
  /// the same place twice in a row; undefined when it never shows.
  async function caretIn(page: Page, band: Box): Promise<Box | undefined> {
    const scale = await page.evaluate(() => window.devicePixelRatio);
    const clip = { x: band.left, y: band.top, width: band.right - band.left, height: band.bottom - band.top };
    let last: Box | undefined;
    for (let attempt = 0; attempt < 40; attempt++) {
      const shot = PNG.sync.read(await page.screenshot({ clip, caret: "initial", scale: "device" }));
      const xs: number[] = [];
      const ys: number[] = [];
      for (let at = 0; at < shot.data.length; at += 4) {
        const [r, g, b] = [shot.data[at]!, shot.data[at + 1]!, shot.data[at + 2]!];
        if (Math.abs(r - CARET.r) < 40 && g < 60 && Math.abs(b - CARET.b) < 40) {
          xs.push((at / 4) % shot.width);
          ys.push(Math.floor(at / 4 / shot.width));
        }
      }
      if (xs.length) {
        const seen = {
          left: band.left + Math.min(...xs) / scale,
          right: band.left + (Math.max(...xs) + 1) / scale,
          top: band.top + Math.min(...ys) / scale,
          bottom: band.top + (Math.max(...ys) + 1) / scale,
        };
        if (last && last.left === seen.left && last.top === seen.top) return seen;
        last = seen;
      }
      await nextFrames(page);
    }
    return last;
  }

  type Op = "focus" | "caret" | "setCaret" | "text" | "paste" | "reset";
  /// One call on the prompt's handle (MarkdownField's `acpmuxMarkdownField`).
  const field = <T>(page: Page, op: Op, arg?: unknown) =>
    page.evaluate(
      ([name, value]) => {
        const element = document.querySelector(".acpmux-md-field") as HTMLElement & {
          acpmuxMarkdownField?: {
            focus(): void;
            caret(): number;
            setCaret(offset: number): void;
            plainText(): string;
            pasteText(text: string): void;
            reset(markdown?: string): void;
          };
        };
        const md = element.acpmuxMarkdownField!;
        switch (name) {
          case "focus":
            md.focus();
            md.setCaret(0);
            return null;
          case "caret":
            return md.caret();
          case "setCaret":
            md.setCaret(value as number);
            return null;
          case "text":
            return md.plainText();
          case "paste":
            md.pasteText(value as string);
            return null;
          case "reset":
            md.reset("");
            return null;
        }
      },
      [op, arg] as const,
    ) as Promise<T>;

  const chipBoxes = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-md .is-titled[data-title]")].map((chip) => {
        const box = chip.getBoundingClientRect();
        const line = chip.closest("p")!.getBoundingClientRect();
        return { left: box.left, right: box.right, top: line.top, bottom: line.bottom };
      }),
    );

  async function open(page: Page, port: number, variant: string, chips: number) {
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: WIDTH, frame: "component" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.addStyleTag({ content: ".acpmux-md { caret-color: rgb(255, 0, 255) !important; }" });
    await page.waitForFunction(
      (count) => document.querySelectorAll(".acpmux-md .is-titled[data-title]").length === count,
      chips,
    );
  }

  /// The caret `offset` characters into the draft: to the start first, a frame before (headless
  /// WebKit's caret does not blink, so one set where it is keeps its old paint).
  const caretAt = async (page: Page, offset: number) => {
    await field(page, "focus");
    await nextFrames(page);
    await field(page, "setCaret", offset);
    await nextFrames(page);
  };

  const run = async (engine: "chromium" | "webkit", launch: () => Promise<Browser>) => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    const browser = await launch();
    const failures: string[] = [];
    try {
      await vite.listen();
      await warmGalleryFrame(vite, ENTRY, engine === "chromium" ? { browser } : {});
      const port = (vite.httpServer!.address() as { port: number }).port;
      const context = await browser.newContext({
        viewport: { width: WIDTH, height: 400 },
        colorScheme: "dark",
        deviceScaleFactor: 2,
      });
      const page = await context.newPage();
      try {
        // The link alone, the caret after its chip: painted, at a text line's height, past the chip.
        await open(page, port, "caret-after-chip", 1);
        await caretAt(page, WORKSPACE.length);
        let [chip] = await chipBoxes(page);
        const after = await caretIn(page, { ...chip!, left: chip!.left, right: chip!.right + 24 });
        if (!after) failures.push(`${engine}: no caret after the chip`);
        else {
          if (after.bottom - after.top < 10)
            failures.push(`${engine}: the caret after the chip is ${after.bottom - after.top}px tall`);
          if (after.left < chip!.right - 1.5)
            failures.push(`${engine}: the caret after the chip is at ${after.left}, inside the chip (${chip!.right})`);
        }
        // ArrowLeft steps over the chip: the caret is painted before it.
        await page.keyboard.press("ArrowLeft");
        await nextFrames(page);
        expect(await field<number>(page, "caret")).toBe(0);
        // The caret before a chip at the line's start: Chromium draws it before the chip's front. Headless
        // WebKit draws no caret at a line's start before an element that takes no input, with or without
        // an empty image to hold it (tried: it cost Chromium its caret too), so there it is reported, not
        // judged; the caret's place is checked above in both, and the caret before a chip after text is
        // judged in both (caret-before-chip below).
        const front = (await page.evaluate(() => {
          const box = document.querySelector(".acpmux-md .is-titled-start")?.getBoundingClientRect();
          return box && { left: box.left, right: box.right };
        }))!;
        const before = await caretIn(page, { ...chip!, left: Math.max(0, front.left - 24), right: front.left + 4 });
        if (engine === "chromium") {
          if (!before) failures.push(`${engine}: no caret before the chip at the line's start`);
          else if (before.left > front.left + 1.5)
            failures.push(`${engine}: the caret before the chip is at ${before.left}, inside the chip`);
        } else
          console.log(`${engine}: the caret before a chip at the line's start ${before ? "shows" : "does not show"}`);
        // ArrowRight steps back over it.
        await page.keyboard.press("ArrowRight");
        expect(await field<number>(page, "caret")).toBe(WORKSPACE.length);
        // Real typing right after the chip: the chip stays, a space before the typed word.
        await page.keyboard.type("x");
        await nextFrames(page);
        expect(await field<string>(page, "text")).toBe(`${WORKSPACE} x`);
        expect((await chipBoxes(page)).length).toBe(1);
        // A second link pasted right after the chip: both chips.
        await field(page, "setCaret", WORKSPACE.length);
        await field(page, "paste", WORKSPACE);
        await page
          .waitForFunction(
            () => document.querySelectorAll(".acpmux-md .is-titled[data-title]").length === 2,
            undefined,
            {
              timeout: 10_000,
            },
          )
          .catch(() => undefined);
        expect(await field<string>(page, "text")).toBe(`${WORKSPACE} ${WORKSPACE} x`);
        expect((await chipBoxes(page)).length).toBe(2);

        // Mid-text: the caret before the chip is painted, in front of it.
        await open(page, port, "caret-before-chip", 1);
        await caretAt(page, "See ".length);
        [chip] = await chipBoxes(page);
        const start = await page.evaluate(
          () => document.querySelector(".acpmux-md .is-titled-start")!.getBoundingClientRect().left,
        );
        const ahead = await caretIn(page, { ...chip!, left: Math.max(0, start - 24), right: start + 4 });
        if (!ahead) failures.push(`${engine}: no caret before the chip`);
        else if (ahead.bottom - ahead.top < 10)
          failures.push(`${engine}: the caret before the chip is ${ahead.bottom - ahead.top}px tall`);
        // Each engine paints its 1px caret on whole pixels, Chromium's just before the insertion point and
        // WebKit's just after it: the caret starts no further in than that.
        else if (ahead.left > start + 1.5)
          failures.push(`${engine}: the caret before the chip is at ${ahead.left}, inside it (${start})`);

        // A Cloud start is out: a real click focuses the prompt, and real keys type into it.
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "starting-chat", width: WIDTH, frame: "component" })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        await field(page, "reset");
        await page.locator(".acpmux-md").click();
        await page.keyboard.type("hi there");
        expect(await field<string>(page, "text")).toBe("hi there");
        expect(await page.evaluate(() => document.activeElement?.closest(".acpmux-md") !== null)).toBe(true);
      } finally {
        await context.close();
      }
    } finally {
      await browser.close();
      await vite.close();
    }
    expect(failures).toEqual([]);
  };

  test("chromium: the caret shows around a link chip, and the chip stays one", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test("webkit: the caret shows around a link chip, and the chip stays one", () =>
    run("webkit", () => webkit.launch({ headless: true })));
});
