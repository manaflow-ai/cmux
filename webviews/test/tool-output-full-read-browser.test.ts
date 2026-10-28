import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";

await requireBrowserLane("tool-output-full-read-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.tool-output-full-read";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE } : {}),
    });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "collapsed" } });
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const stage = async (variant: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 760, height: 820 } });
    await page.goto(`${base}${galleryFrame(entry, { variant, colorScheme: "dark" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    if (variant !== "collapsed") {
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
      const report = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      );
      expect(playFailures(report)).toEqual([]);
    }
    return page;
  };
  test("a fetched Markdown result scrolls to its final line, drops the fade there, and expands", async () => {
    const page = await stage("compact");
    try {
      expect(await page.locator(".cv-tool-output__markdown h2").first().textContent()).toBe("Network map: summary");
      const body = page.locator(".cv-tool-output__markdown");
      expect(await body.evaluate((node) => node.scrollHeight > node.clientHeight)).toBe(true);
      await body.evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await page.waitForFunction(
        () => !document.querySelector(".cv-tool-output__markdown")?.hasAttribute("data-more-below"),
      );
      expect(await body.evaluate((node) => getComputedStyle(node).maskImage)).toBe("none");
      await page.locator(".cv-output-more").click();
      expect(await body.getAttribute("data-preview")).toBe("all");
      expect(await body.textContent()).toContain("End of the complete result.");
      expect(await body.evaluate((node) => node.clientHeight)).toBeGreaterThan(300);
    } finally {
      await page.close();
    }
  });
  test("a single wrapped line always has an expansion control", async () => {
    const page = await stage("wrapped-line");
    try {
      await page.getByRole("button", { name: "Show all 1 line", exact: true }).waitFor();
      await page.getByRole("button", { name: "Show all 1 line", exact: true }).click();
      expect(await page.getByRole("button", { name: "Show less", exact: true }).count()).toBe(1);
    } finally {
      await page.close();
    }
  });
  test("an expanded wrapped line drops stale disclosure after its content or width fits", async () => {
    for (const change of ["content", "width"]) {
      const page = await stage("wrapped-line");
      try {
        const body = page.locator("pre.cv-tool-output");
        await page.getByRole("button", { name: "Show all 1 line", exact: true }).click();
        await page.getByRole("button", { name: "Show less", exact: true }).waitFor();
        await body.evaluate((node, change) => {
          if (change === "content") node.textContent = "Short result.";
          else node.style.width = "18000px";
        }, change);
        await page.waitForFunction(() => !document.querySelector("pre.cv-tool-output")?.hasAttribute("data-preview"));
        expect(await body.getAttribute("data-more-below")).toBeNull();
        expect(await page.locator(".cv-output-more").count()).toBe(0);
      } finally {
        await page.close();
      }
    }
  });
  test("Raw shows the complete source while JSON and logs remain monospace", async () => {
    const page = await stage("expanded");
    try {
      const body = page.locator(".cv-tool-output__markdown");
      expect(await body.evaluate((node) => node.scrollTop)).toBe(0);
      await body.evaluate(async (node) => {
        node.scrollTop = 100;
        node.style.width = `${node.clientWidth - 40}px`;
        node.append(node.ownerDocument.createTextNode("More sample output."));
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      });
      expect(await body.evaluate((node) => node.scrollTop)).toBe(100);
      await page.getByRole("button", { name: "Raw", exact: true }).click();
      expect(await page.locator("pre.cv-tool-output").textContent()).toContain("**End of the complete result.**");
    } finally {
      await page.close();
    }
    for (const variant of ["json", "log"]) {
      const mono = await stage(variant);
      try {
        expect(await mono.locator("pre.cv-tool-output").count()).toBe(1);
        expect(await mono.locator(".cv-tool-output__markdown").count()).toBe(0);
      } finally {
        await mono.close();
      }
    }
  });
});
