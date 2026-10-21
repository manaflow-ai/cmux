// Under Reduce Motion the pages' shared stylesheet (pages/shared/desktop.css) sets every element's
// transition-duration to 0.01ms. transition-property's initial value is `all`, so the transcript's
// spacer, the scroller's extent, transitioned its height for that 0.01ms: a followed view set its
// offset against the old height in the same frame, clamped short of the end and stayed there. The
// spacer keeps no transition. This loads the real stylesheets in Chromium under emulated Reduce
// Motion, grows the spacer and lists the transitions it starts.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-spacer-reduce-motion.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-spacer-reduce-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript spacer reduce motion", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  test("a growing transcript spacer starts no transition under Reduce Motion", async () => {
    const page = await browser!.newPage();
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.setContent(
      `<style>${css}</style><div class="acpmux-scroll" style="height:300px"><div class="acpmux-spacer" style="height:400px"></div></div>`,
    );
    const started = await page.evaluate(async () => {
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const spacer = document.querySelector<HTMLElement>(".acpmux-spacer")!;
      spacer.style.height = "2000px";
      return spacer.getAnimations().map((animation) => (animation as CSSTransition).transitionProperty ?? "?");
    });
    await page.close();
    expect(started).toEqual([]);
  });
});
