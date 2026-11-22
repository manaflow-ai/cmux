// The caret after the composer's own edits: a `/` command or an `@` mention picked from its list,
// a prompt brought back with ↑ (and ↓ back to the empty prompt), and Send clearing the prompt. In
// each the caret stands where the edit leaves it in the first frame that shows the edit, never at
// the prompt's start first. Leo, 2026-11-22: "idk if there are other places where our
// caret/typing/perciee is lagging liek that... maybe more".
//
// Same shape as composer-caret-frames.browser.test.ts: the real composer in the gallery
// (agent-pane.composer), the caret read after every painted frame (support/caretFrames.ts), one
// `CARET_FRAMES` JSON line per case and engine. `CMUX_CARET_REPORT_ONLY=1` prints without failing.
// cmux-web-test-timeout: 600
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { FRAME_MS, installCaretTrace, judgeCaret, type CaretTrace } from "./support/caretFrames";

await requireBrowserLane("composer-caret-frames-pickers.browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  const ENTRY = "agent-pane.composer";
  const FIELD = ".acpmux-md";
  const reportOnly = process.env.CMUX_CARET_REPORT_ONLY === "1";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const)
      browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: browsers.get("chromium")!, params: { variant: "caret-frames-draft" } });
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function stage(engine: string, variant: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 1000, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1000 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.waitForSelector(`${FIELD}[contenteditable='true']`);
    await installCaretTrace(page);
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "inline" }));
    await page.focus(FIELD);
    return page;
  }

  /** Puts the caret `offset` characters into the prompt's text (the end when past it). */
  const caretAt = (page: Page, offset: number) =>
    page.evaluate((at) => {
      const field = document.querySelector(".acpmux-md-field") as unknown as {
        acpmuxMarkdownField?: { setCaret(at: number): void; focus(): void };
      };
      field.acpmuxMarkdownField!.focus();
      field.acpmuxMarkdownField!.setCaret(at);
    }, offset);
  const quietFrames = async (page: Page, frames = 20) => {
    for (let frame = 0; frame < frames; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };
  const startTrace = (page: Page) => page.evaluate(() => window.cmuxCaretTrace!.start(".acpmux-md"));
  const promptText = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-md")?.textContent?.replace(/\u00a0/g, " ") ?? "");
  const waitText = (page: Page, test: string, mode: "is" | "has") =>
    page.waitForFunction(
      ({ test, mode }) => {
        const text = (document.querySelector(".acpmux-md")?.textContent ?? "").replace(/\u00a0/g, " ").trim();
        return mode === "is" ? text === test : text.includes(test);
      },
      { test, mode },
      { timeout: 10_000 },
    );

  /** The `/` list open with its first row highlighted (the slash-menu stage's play typed `/`). */
  const slashOpen = (page: Page) => page.waitForSelector("#acpmux-slash-menu [role='option']");
  /** The mention-picker stage wrote `Fix @README.md`; a second `@rea` opens the list on the file rows. */
  const mentionOpen = async (page: Page) => {
    await caretAt(page, Number.MAX_SAFE_INTEGER);
    await page.keyboard.type(" @rea");
    await page.waitForFunction(() =>
      [...document.querySelectorAll(".acpmux-mention-row[role=option]")].some((row) => row.textContent?.includes("README.md")),
    );
    await quietFrames(page, 4);
  };

  type Case = {
    name: string;
    variant: string;
    /** Sets up, makes the edit and waits until it settled. */
    run(page: Page): Promise<void>;
  };
  const CASES: Case[] = [
    {
      name: "slash pick with Tab",
      variant: "slash-menu",
      async run(page) {
        await slashOpen(page);
        await quietFrames(page, 4);
        await startTrace(page);
        await page.keyboard.press("Tab");
        await page.waitForFunction(() => !document.querySelector("#acpmux-slash-menu [role='option']"), undefined, {
          timeout: 10_000,
        });
        await quietFrames(page);
      },
    },
    {
      name: "slash pick with a click",
      variant: "slash-menu",
      async run(page) {
        await slashOpen(page);
        await page.keyboard.type("re");
        await page.waitForFunction(() =>
          [...document.querySelectorAll("#acpmux-slash-menu [role='option']")].some((row) => row.textContent?.includes("review")),
        );
        await quietFrames(page, 4);
        await startTrace(page);
        await page
          .locator("#acpmux-slash-menu [role='option']")
          .filter({ hasText: "review" })
          .first()
          .click();
        await waitText(page, "/review", "has");
        await quietFrames(page);
      },
    },
    {
      name: "mention pick with Tab",
      variant: "mention-picker",
      async run(page) {
        await mentionOpen(page);
        await startTrace(page);
        await page.keyboard.press("Tab");
        await waitText(page, "Fix @README.md @README.md", "has");
        await quietFrames(page);
      },
    },
    {
      name: "mention pick with a click",
      variant: "mention-picker",
      async run(page) {
        await mentionOpen(page);
        await startTrace(page);
        await page.locator(".acpmux-mention-row[role=option]").filter({ hasText: "README.md" }).first().click();
        await waitText(page, "Fix @README.md @README.md", "has");
        await quietFrames(page);
      },
    },
    {
      name: "history up on the empty prompt",
      variant: "caret-frames-empty",
      async run(page) {
        await quietFrames(page, 4);
        await startTrace(page);
        await page.keyboard.press("ArrowUp");
        await waitText(page, "Add retries with backoff to the fetch helper", "is");
        await quietFrames(page);
      },
    },
    {
      name: "history down back to the empty prompt",
      variant: "caret-frames-empty",
      async run(page) {
        await page.keyboard.press("ArrowUp");
        await waitText(page, "Add retries with backoff to the fetch helper", "is");
        await quietFrames(page);
        await startTrace(page);
        await page.keyboard.press("ArrowDown");
        await waitText(page, "", "is");
        await quietFrames(page);
      },
    },
    {
      name: "send with Return clears the prompt",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, Number.MAX_SAFE_INTEGER);
        await quietFrames(page, 4);
        await startTrace(page);
        await page.keyboard.press("Enter");
        await waitText(page, "", "is");
        await quietFrames(page, 40);
      },
    },
    {
      name: "send with a click on Send clears the prompt",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, Number.MAX_SAFE_INTEGER);
        await quietFrames(page, 4);
        await startTrace(page);
        await page.locator(".acpmux-send.acpmux-send-ready").first().click();
        await waitText(page, "", "is");
        await quietFrames(page, 40);
      },
    },
  ];

  for (const engine of ["chromium", "webkit"])
    for (const each of CASES)
      test(`${engine}: ${each.name}: the caret is in place every frame and settles in time`, async () => {
        const page = await stage(engine, each.variant);
        try {
          await each.run(page);
          const trace = (await page.evaluate(() => window.cmuxCaretTrace!.stop())) as CaretTrace;
          const verdict = judgeCaret(trace);
          // When the frame showing the new text first painted, against the caret's settling.
          const text = await promptText(page);
          console.log(
            `CARET_FRAMES ${JSON.stringify({
              engine,
              case: each.name,
              wrongFrames: verdict.wrongFrames.length,
              inputToCaretMs: verdict.inputToCaretMs === null ? null : Math.round(verdict.inputToCaretMs * 10) / 10,
              framesToSettle: verdict.framesToSettle,
              frames: trace.frames.length,
              finalFocused: trace.final.focused,
              finalShown: trace.final.shown,
              text: text.slice(0, 60),
              firstFrames: trace.frames.slice(0, 4).map((frame) => ({
                ms: Math.round((frame.at - trace.inputAt) * 10) / 10,
                focused: frame.focused,
                x: frame.shown ? Math.round(frame.shown.x) : null,
                tx: frame.truth ? Math.round(frame.truth.x) : null,
              })),
              firstWrong: verdict.wrongFrames.slice(0, 3),
            })}`,
          );
          if (reportOnly) return;
          expect(trace.frames.length).toBeGreaterThan(0);
          expect(verdict.wrongFrames).toEqual([]);
          expect(verdict.inputToCaretMs).not.toBeNull();
          expect(verdict.inputToCaretMs!).toBeLessThanOrEqual(FRAME_MS + 1);
        } finally {
          await page.close();
        }
      });
});
