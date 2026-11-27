// cmux-web-test-timeout: 600
// Visual parity of the agent pane states whose styles moved from pane-level `:has()` rules to state
// attributes: each gallery state in light and dark, as a still and as a digest of every element's
// computed style. Run it at the commit before the change and at the change: the digests and stills
// must match. A capture, not a gate: it runs only when asked (PANE_HAS_PARITY=1), through cmux-ci,
// and writes the stills to $FAST_CHECKS_OUT/pane-has-parity when that is set.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type State = { entry: string; variant: string; width: number; height: number; hover?: string };

await requireBrowserLane("pane-has-parity.browser.test.ts", async () => {
  // A measurement, not a gate: it runs only when asked (PANE_HAS_PARITY=1), through cmux-ci.
  if (process.env.PANE_HAS_PARITY !== "1") {
    describe.skip("pane :has parity (PANE_HAS_PARITY=1)", () => test("chromium", () => {}));
    return;
  }
  /** The states each replaced rule draws: the composer's grid look (and Codex's, which it must not
   *  reach), its field menu open, and the PR links beside a reply's and a turn's action row. */
  const STATES: State[] = [
    { entry: "agent-pane.composer", variant: "idle", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "focused", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "context-menu", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "long-draft", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "image-attached", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "working-queue", width: 760, height: 420 },
    { entry: "agent-pane.composer", variant: "footer-harness-codex", width: 760, height: 420 },
    { entry: "agent-pane.composer-look", variant: "claude-chat", width: 760, height: 420 },
    { entry: "agent-pane.composer-look", variant: "codex-chat", width: 760, height: 420 },
    { entry: "agent-pane.composer-scrollbar", variant: "edge", width: 760, height: 420 },
    { entry: "agent-pane.composer-scrollbar", variant: "lane", width: 760, height: 420 },
    { entry: "agent-pane.composer-scrollbar", variant: "outside", width: 760, height: 420 },
  ];
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "pane-has-parity") : undefined;
  if (out) fs.mkdirSync(out, { recursive: true });
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const entry of new Set(STATES.map((state) => state.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: STATES.find((s) => s.entry === entry)!.variant },
      });
  }, 280_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Every element's tag, classes and full computed style, in document order. */
  const styleDigest = (page: Page) =>
    page.evaluate(() => {
      const lines: string[] = [];
      for (const node of Array.from(document.querySelectorAll("body *"))) {
        const css = getComputedStyle(node);
        const props: string[] = [];
        for (let index = 0; index < css.length; index += 1) {
          const name = css.item(index);
          props.push(`${name}:${css.getPropertyValue(name)}`);
        }
        lines.push(`${node.tagName}.${node.getAttribute("class") ?? ""}{${props.join(";")}}`);
      }
      return lines.join("\n");
    });

  for (const colorScheme of ["light", "dark"] as const)
    for (const state of STATES) {
      const name = `${state.entry}.${state.variant}${state.hover ? ".hover" : ""}.${colorScheme}`;
      test(name, async () => {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        const page = await browser!.newPage({
          viewport: { width: state.width, height: state.height },
        });
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(state.entry, { variant: state.variant, colorScheme, reducedMotion: "true" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
          if (state.hover) await page.hover(state.hover);
          await page.evaluate(
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          );
          const styles = await styleDigest(page);
          if (out) fs.writeFileSync(path.join(out, `${name}.styles.txt`), styles);
          const digest = createHash("sha256").update(styles).digest("hex").slice(0, 16);
          const png = await page.screenshot({ animations: "disabled", caret: "hide" });
          const pixels = createHash("sha256").update(png).digest("hex").slice(0, 16);
          if (out) fs.writeFileSync(path.join(out, `${name}.png`), png);
          console.log(`PANE-PARITY ${name} style=${digest} png=${pixels}`);
          expect(png.length).toBeGreaterThan(0);
        } finally {
          await page.close();
        }
      });
    }
});
