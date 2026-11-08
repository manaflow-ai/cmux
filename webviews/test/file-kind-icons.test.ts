// A file chip's icon says what the file is, as ChatGPT's report draws its "Supporting artifacts:"
// links (Leo, 2026-11-02: "see this is the kinda scenario we wanna be able to display super
// nicely"): a page for a document, braces for code and data, a terminal mark for a log.
//
// In gallery entry agent-pane.long-report, variant report (light and dark), each supporting
// artifact's chip draws its kind's icon: manifest.md a page, git-discovery.log the log mark,
// pr-evidence.json and follow-ups.json braces. In agent-pane.path-chip, the kind-* variants draw the
// same, and under the file-kind-icon experiment's `page` arm every chip draws the page, as before.
//
// CMUX_FILE_KIND_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes 2x stills of the
// artifacts paragraph in each theme.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("file-kind-icons.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.long-report";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const EXPECTED: Record<string, string> = {
    "manifest.md": "doc",
    "git-discovery.log": "log",
    "pr-evidence.json": "code",
    "follow-ups.json": "code",
  };

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("file kind icons", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "report" }, timeoutMs: 200_000 });
    await warmGalleryFrame(vite, "agent-pane.path-chip", { browser, params: { variant: "kind-log" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (theme: string, arm?: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 900, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const params = { variant: "report", width: 900, theme, reducedMotion: "true", exp: arm && "file-kind-icon", arm };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, params)}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Each artifact chip's file name and the kind its icon draws. */
  const kinds = (page: Page): Promise<Record<string, string>> =>
    page.evaluate((names) => {
      const found: Record<string, string> = {};
      for (const chip of document.querySelectorAll<HTMLElement>("[data-path], a.cv-link")) {
        const where = chip.getAttribute("data-path") ?? chip.getAttribute("href") ?? "";
        const name = names.find((candidate) => where.endsWith(candidate));
        if (!name) continue;
        const icon = chip.querySelector("svg");
        const kind = [...(icon?.classList ?? [])].find((name) => name.startsWith("cv-file-kind--"));
        found[name] = kind?.slice("cv-file-kind--".length) ?? "none";
      }
      return found;
    }, Object.keys(EXPECTED));

  const artifacts = process.env.CMUX_FILE_KIND_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;
  const still = async (page: Page, name: string) => {
    if (!artifacts) return;
    const box = await page.evaluate(() => {
      const paragraph = [...document.querySelectorAll("p")].find((p) => p.textContent?.startsWith("Supporting"));
      const rect = paragraph?.getBoundingClientRect();
      return rect ? { x: rect.left - 16, y: rect.top - 16, width: rect.width + 32, height: rect.height + 32 } : null;
    });
    await mkdir(artifacts, { recursive: true });
    await page.screenshot({ path: path.join(artifacts, `file-kind-${name}.png`), ...(box && { clip: box }) });
  };

  for (const theme of THEMES) {
    test(`each supporting artifact's chip draws its kind (${theme.file})`, async () => {
      const page = await open(theme.name);
      try {
        await still(page, `typed-${theme.file}`);
        expect(await kinds(page)).toEqual(EXPECTED);
      } finally {
        await page.close();
      }
    });
  }

  // The arms compare on the path chip's own entry (agent-pane.path-chip), which carries the experiment.
  const chipKind = async (variant: string, arm?: string): Promise<string> => {
    const page = await browser.newPage({ viewport: { width: 640, height: 200 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const params = { variant, width: 640, reducedMotion: "true", exp: arm && "file-kind-icon", arm };
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.path-chip", params)}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.waitForSelector(".cv-chip svg");
      return page.evaluate(() => {
        const icon = document.querySelector(".cv-chip svg");
        const kind = [...(icon?.classList ?? [])].find((name) => name.startsWith("cv-file-kind--"));
        return kind?.slice("cv-file-kind--".length) ?? "none";
      });
    } finally {
      await page.close();
    }
  };

  test("the path chip's kind variants: typed by default, one page under the page arm", async () => {
    const variants = ["kind-document", "kind-data", "kind-log"];
    const typed: string[] = [];
    const page: string[] = [];
    for (const variant of variants) {
      typed.push(await chipKind(variant));
      page.push(await chipKind(variant, "page"));
    }
    expect(typed).toEqual(["doc", "code", "log"]);
    expect(page).toEqual(["doc", "doc", "doc"]);
  });
});
