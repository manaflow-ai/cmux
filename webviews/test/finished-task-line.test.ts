// A finished turn keeps the sub-session it started in sight once its work folds: one line with the
// task's title (not its short name), its done mark and a chevron after them, which opens the task's
// chat, where its report is. ChatGPT keeps "✓ Review October engineering work ›" in its lead chat
// (Leo, 2026-11-02: "see this is the kinda scenario we wanna be able to display super nicely").
//
// In gallery entry agent-pane.long-report, variant lead-finished, light and dark:
// - the shipped arm (after-fold): after the turn ends, a visible line names the task by its title,
//   sits under the fold and above the turn's reply, and a click on it asks the app to open that chat;
// - the after-reply arm draws the same line under the reply; the card arm keeps the sub-session's
//   own card out of the fold and draws no line;
// - while the turn still runs (lead-running), no task line draws: the live card is in sight.
//
// CMUX_TASK_LINE_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes 2x stills of each
// arm in each theme.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("finished-task-line.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.long-report";
  const TITLE = "Review October engineering work";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("finished task line", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "lead-finished" }, timeoutMs: 200_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, theme: string, arm?: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 400, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const params = { variant, width: 400, theme, reducedMotion: "true", exp: arm && "finished-task-look", arm };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, params)}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  type Placed = {
    lines: { text: string; top: number; height: number; state: string | null }[];
    fold: number | null;
    reply: number | null;
    startCard: boolean;
    chevron: { right: boolean } | null;
  };
  /** The task lines, the fold row's and the last reply's tops, and whether a start card is in sight. */
  const placed = (page: Page): Promise<Placed> =>
    page.evaluate(() => {
      const top = (element: Element | null | undefined) => (element ? element.getBoundingClientRect().top : null);
      const lines = [...document.querySelectorAll<HTMLElement>(".cv-task-line")].map((line) => ({
        text: line.textContent ?? "",
        top: line.getBoundingClientRect().top,
        height: line.getBoundingClientRect().height,
        state: line.getAttribute("data-task-line"),
      }));
      const replies = [...document.querySelectorAll(".acpmux-row.acpmux-assistant")];
      const glyph = document.querySelector(".cv-task-line .cv-rotor");
      const box = glyph?.getBoundingClientRect();
      const ink = glyph?.querySelector("path")?.getBoundingClientRect();
      return {
        chevron: box && ink ? { right: ink.height > ink.width } : null,
        lines,
        fold: top(document.querySelector(".cv-worked, [data-row-kind='worked']")),
        reply: top(replies.at(-1)),
        // The sub-session's own card, by its short name, in sight outside any task line.
        startCard: [...document.querySelectorAll<HTMLElement>(".acpmux-row")].some(
          (row) =>
            row.getBoundingClientRect().height > 0 &&
            !row.querySelector(".cv-task-line") &&
            /october-review/.test(row.textContent ?? ""),
        ),
      };
    });

  const artifacts = process.env.CMUX_TASK_LINE_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;
  const still = async (page: Page, name: string) => {
    if (!artifacts) return;
    await mkdir(artifacts, { recursive: true });
    await page.screenshot({ path: path.join(artifacts, `task-line-${name}.png`) });
  };

  for (const theme of THEMES) {
    test(`after the turn ends, a visible line names the task and opens its chat (${theme.file})`, async () => {
      const page = await open("lead-finished", theme.name);
      try {
        const found = await placed(page);
        await still(page, `after-fold-${theme.file}`);
        expect(found.lines).toHaveLength(1);
        const [line] = found.lines;
        expect(line!.text).toContain(TITLE);
        expect(line!.text).not.toContain("october-review");
        expect(line!.state).toBe("done");
        expect(line!.height).toBeGreaterThan(0);
        // It opens another chat: its chevron points right (taller than wide), after the words.
        expect(found.chevron?.right).toBe(true);
        // Under the fold, above the reply.
        expect(found.fold).not.toBeNull();
        expect(line!.top).toBeGreaterThan(found.fold!);
        expect(line!.top).toBeLessThan(found.reply!);
        // A click asks the app to open the task's chat.
        await page.evaluate(() => {
          const handler = (
            window as unknown as {
              webkit: { messageHandlers: { agentSession: { postMessage: (m: unknown) => unknown } } };
            }
          ).webkit.messageHandlers.agentSession;
          const post = handler.postMessage;
          const calls: unknown[] = [];
          (window as unknown as { __taskCalls: unknown[] }).__taskCalls = calls;
          handler.postMessage = (message: unknown) => {
            calls.push(message);
            return post(message);
          };
        });
        await page.click(".cv-task-line");
        const calls = await page.evaluate(
          () =>
            (window as unknown as { __taskCalls: { method?: string; params?: { sessionId?: string } }[] }).__taskCalls,
        );
        expect(calls.some((call) => call.params?.sessionId === "sub-october-review")).toBe(true);
      } finally {
        await page.close();
      }
    });

    test(`the after-reply arm draws the line under the reply (${theme.file})`, async () => {
      const page = await open("lead-finished", theme.name, "after-reply");
      try {
        const found = await placed(page);
        await still(page, `after-reply-${theme.file}`);
        expect(found.lines).toHaveLength(1);
        expect(found.lines[0]!.top).toBeGreaterThan(found.reply!);
      } finally {
        await page.close();
      }
    });

    test(`the card arm keeps the sub-session's card out of the fold (${theme.file})`, async () => {
      const page = await open("lead-finished", theme.name, "card");
      try {
        const found = await placed(page);
        await still(page, `card-${theme.file}`);
        expect(found.lines).toHaveLength(0);
        expect(found.startCard).toBe(true);
      } finally {
        await page.close();
      }
    });
  }

  test("while the turn runs, no task line draws", async () => {
    const page = await open("lead-running", THEMES[0]!.name);
    try {
      expect((await placed(page)).lines).toHaveLength(0);
    } finally {
      await page.close();
    }
  });
});
