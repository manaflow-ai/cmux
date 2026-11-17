// cmux-web-test-timeout: 600
// l10n-allow-file: test labels, not shipped UI.
// cmux#45162: the agent pane drew an "Agent may be stuck" card with a "Nudge with hint" button,
// and the nudge put "The agent may be stuck: …" into the composer. It showed on chats that were not
// stuck (a signed-out Codex chat among them). The pane no longer guesses: with the daemon's loop
// episode and silent-turn fields in the chat's summary it draws no card, ring, nudge or injected
// draft, and a real failure keeps its error card.
//
// Real gallery frames (agent-pane.no-stuck-guess) in real Chromium from Playwright; CI fails the file
// when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Seen = { stuckNodes: number; stuckWords: string[]; draft: string; errorCards: number };

await requireBrowserLane("agent-pane-no-stuck-guess.test.ts", async () => {
  setDefaultTimeout(540_000);
  const ENTRY = "agent-pane.no-stuck-guess";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 720, height: 620 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 720 })}`);
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    return page;
  }

  function look(): Seen {
    const text = document.body.textContent ?? "";
    return {
      stuckNodes: document.querySelectorAll(".acpmux-stuck-banner, .acpmux-stuck-nudge, [data-stuck]").length,
      stuckWords: ["may be stuck", "Nudge with hint", "try a different approach", "the same error in auth.rs:88"].filter(
        (words) => text.includes(words),
      ),
      draft:
        document
          .querySelector(".acpmux-composer > .acpmux-composer-box [contenteditable='true']")
          ?.textContent?.trim() ?? "",
      errorCards: document.querySelectorAll(".cv-turn-error").length,
    };
  }

  test("a chat the daemon calls looping or silent shows no stuck card, ring, nudge or draft", async () => {
    const page = await open("running");
    try {
      expect(await page.evaluate(look)).toEqual({ stuckNodes: 0, stuckWords: [], draft: "", errorCards: 0 });
    } finally {
      await page.close();
    }
  });

  test("a signed-out Codex chat keeps its real error card and shows no stuck guess", async () => {
    const page = await open("signed-out-codex");
    try {
      await page.locator(".cv-turn-error").first().waitFor({ timeout: 30_000 });
      const seen = await page.evaluate(look);
      expect({ ...seen, errorCards: Math.min(seen.errorCards, 1) }).toEqual({
        stuckNodes: 0,
        stuckWords: [],
        draft: "",
        errorCards: 1,
      });
    } finally {
      await page.close();
    }
  });
});
