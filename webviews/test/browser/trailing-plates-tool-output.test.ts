import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "../support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import path from "node:path";

await requireBrowserLane("trailing-plates-tool-output.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "../..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.tool-group-overlap", { timeoutMs: 120_000 });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const mode of ["light", "dark"] as const) {
    test(`${mode}: hovered tool output actions have no plate`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 860, height: 680 }, reducedMotion: "reduce" });
      await page.addInitScript(() => {
        localStorage.setItem("cmux.experiments", JSON.stringify({ "hover-actions": "all" }));
      });
      // The frame emulates its own media (gallery/frame/media.ts): Reduce Motion there too, so the
      // actions' fade in (transcript-hover-fade.test.ts) has nothing to wait for when they are read.
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.tool-group-overlap", { variant: "mixed", colorScheme: mode, reducedMotion: 1 })}`,
      );
      await page.locator(".cv-tool.is-toggle").first().click();
      await page.locator(".cv-tool.is-toggle").filter({ hasText: "Read coordination.md" }).click();
      const output = page.locator(".cv-tool-output__box").first();
      await output.waitFor();
      const actions = output.locator(".cv-tool-output__actions");
      await actions.waitFor();
      const button = actions.locator("button").first();
      // Focus is deterministic in headless CI; :focus-within reveals the same actions without
      // depending on the pointer still being over the output box when styles are sampled.
      await button.focus();
      // Reduce Motion still runs every transition, for 0.01ms (shared/desktop.css): the reveal's
      // opacity reads 0 in the frame it starts. Read the actions once it has run.
      await actions.evaluate((node) => Promise.all(node.getAnimations().map((animation) => animation.finished)));
      const style = await actions.evaluate((node) => {
        const computed = getComputedStyle(node);
        return {
          background: computed.backgroundColor,
          borderRadius: computed.borderTopLeftRadius,
          opacity: computed.opacity,
        };
      });
      expect(style.opacity).toBe("1");
      expect(await actions.locator("button").count()).toBe(2);
      for (const button of await actions.locator("button").all()) expect(await button.boundingBox()).not.toBeNull();
      const dir = process.env.ORCH_PLATES_CAPTURE_DIR;
      if (dir) await page.screenshot({ path: `${dir}/tool-output-${mode}.png` });
      expect(style.background).toBe("rgba(0, 0, 0, 0)");
      expect(style.borderRadius).toBe("0px");
      await button.hover();
      expect(await button.evaluate((node) => getComputedStyle(node).backgroundColor)).not.toBe("rgba(0, 0, 0, 0)");
      const text = output.locator("pre");
      const expectClearCorner = async () => {
        const textBounds = await text.boundingBox();
        const actionsBounds = await actions.boundingBox();
        expect(textBounds!.x + textBounds!.width).toBeLessThanOrEqual(actionsBounds!.x);
      };
      await expectClearCorner();
      await button.click();
      expect(await text.getAttribute("data-wrap")).toBe("false");
      await expectClearCorner();
      await page.close();
    });
  }
});
