// l10n-allow-file: test fixture drafts, not shipped UI.
// The last launch's copy gives way early only when the live composer shows all the copy's does
// (chatSnapshot/live.ts `promptMatchesChatSnapshot`: its prompt, its whole text, its tiles and its
// height). Any lasting difference the copy carries (a placeholder, a picker label, a focus ring, a
// pixel of font metrics) would hold every restart to draftSettleHold.ts's 2 s cap, the wait
// cmux#45669 removed (cmux#45994 review). So a chat's copy, written by the real writer
// (capture.ts) from the real pane and drawn by the real painter (paint.ts) over it, matches the live
// composer it was written from: with no draft, and with a tall multi-line one. Real Chromium against
// the pane's dev entry and a stand-in acpmux (support/papercutChat.ts). The page's sheet the copy
// links is the dev page's rules joined, and its copy sheet those rewritten for the shadow tree
// (snapshotCss), as build-agent-pane-web.sh writes pane.css and pane-copy.css.
// first-load-after-restart.bench.ts prints how each restart's wait ran out (`draft wait`). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/chat-snapshot-handover-no-cap.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-snapshot-handover-no-cap.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 6, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const open = () => pane.open({ width: 900, height: 700 });

  /// Writes the page's copy, draws it over the page and, in the task it shows in (before the
  /// live page could take over), says whether the live composer matches it and what differs.
  const handover = async (page: Page) => {
    // The dev server's sheets, in order, as the app's one linked sheet holds the build's.
    const css = await page.evaluate(() =>
      [...document.querySelectorAll("style")]
        .filter((style) => !style.closest("#root"))
        .map((style) => style.textContent ?? "")
        .join("\n"),
    );
    // Served from the page's origin: its policy takes sheets from there only.
    const served: Record<string, string> = { "/__test-pane.css": css, "/__test-pane-copy.css": snapshotCss(css) };
    await page.route(/\/__test-pane(-copy)?\.css$/, (route) =>
      route.fulfill({ contentType: "text/css", body: served[new URL(route.request().url()).pathname] ?? "" }),
    );
    return await page.evaluate(async () => {
      const link = document.createElement("link");
      link.rel = "stylesheet";
      link.id = "cmux-pane-styles";
      link.href = "/__test-pane.css";
      link.dataset.copy = "__test-pane-copy.css";
      await new Promise((loaded, failed) => {
        link.onload = loaded;
        link.onerror = () => failed(new Error("the page's stand-in sheet did not load"));
        document.head.appendChild(link);
      });
      // The app's page holds these rules in its linked sheet only, not as `<style>` elements too:
      // left in, the writer would count them twice as page sheets and go past its size cap.
      for (const style of Array.from(document.querySelectorAll("style"))) {
        if (!style.closest("#root") && style.id !== "cmux-theme") style.remove();
      }
      // The pane's dev server serves src/agent-session/acpmux at its root.
      const at = (file: string) => `/chatSnapshot/${file}`;
      const capture = await import(/* @vite-ignore */ at("capture.ts"));
      const paint = await import(/* @vite-ignore */ at("paint.ts"));
      const live = await import(/* @vite-ignore */ at("live.ts"));
      const snapshot = capture.captureSnapshot(document, "test-theme");
      (window as unknown as Record<string, unknown>).__cmuxChatSnapshotTheme = "test-theme";
      return await new Promise<{ painted: boolean; matches?: boolean; differs?: string | null; miss?: string }>(
        (done) => {
          const painted = paint.paintSnapshot(document, snapshot, {
            shown: () =>
              done({
                painted: true,
                matches: live.promptMatchesChatSnapshot(),
                differs: live.composerDifference() ?? null,
              }),
          });
          if (!painted) done({ painted: false, miss: capture.captureMiss() });
        },
      );
    });
  };

  test("a chat with no draft: the copy's composer matches the live one, so the copy goes without the cap", async () => {
    const page = await open();
    try {
      expect(await handover(page)).toEqual({ painted: true, matches: true, differs: null });
    } finally {
      await page.close();
    }
  });

  test("a tall multi-line draft: the copy's composer matches the live one too", async () => {
    const page = await open();
    try {
      const prompt = page.locator(".acpmux-composer-box .acpmux-md-root").first();
      await prompt.click();
      for (let line = 1; line <= 6; line += 1) {
        await page.keyboard.type(`line ${line} of the unsent draft`);
        if (line < 6) await page.keyboard.press("Shift+Enter");
      }
      const box = page.locator(".acpmux-composer").first();
      const before = (await box.boundingBox())!.height;
      // The draft grew the composer: its height is what the copy must keep.
      expect(before).toBeGreaterThan(80);
      await prompt.blur();
      expect(await handover(page)).toEqual({ painted: true, matches: true, differs: null });
    } finally {
      await page.close();
    }
  });
});
