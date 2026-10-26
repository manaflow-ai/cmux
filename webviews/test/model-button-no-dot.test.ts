// cmux-web-test-timeout: 300
// Leo 2026-10-22, ask-4b7bcd11c2: "he sees a dot? idk why we dont see a dot", then ask-24514f48c1:
// "BRO WTF NO WE FUCKING HATE THE DOT". A build read "Opus 5.5 • Medium" on the composer's model
// button: an agent CLI update drew a round accent dot between the model and its effort. The button
// reads "Opus 5.5 Medium": no bullet or middot in its text or its drawn pseudo-elements, and no
// element in it is a small round dot, with or without an update on offer.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/model-button-no-dot.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-button-no-dot.test.ts", async () => {
  const ENTRY = "agent-pane.model-button-default-effort";
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`model button no dot: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("model button no dot", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 640, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, {
      browser: [...browsers.values()][0],
      params: { variant: "profile-default" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, variant: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 640, height: 360 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /// What the model button draws: its text as read (each drawn label's attr() content in place), every
  /// pseudo-element's content, and any element whose painted box is a small circle.
  const drawn = (page: Page) =>
    page.evaluate(() => {
      const button = document.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button");
      if (!button) throw new Error("no model button");
      const visible = (element: Element) => {
        const style = getComputedStyle(element);
        const box = element.getBoundingClientRect();
        return style.display !== "none" && style.visibility !== "hidden" && box.width > 0 && box.height > 0;
      };
      const pseudo: string[] = [];
      const dots: string[] = [];
      const words: string[] = [];
      const walk = (node: Node) => {
        if (node.nodeType === Node.TEXT_NODE) {
          words.push(node.textContent ?? "");
          return;
        }
        if (!(node instanceof Element) || !visible(node)) return;
        for (const which of ["::before", "::after"] as const) {
          const content = getComputedStyle(node, which).content;
          if (content && content !== "none" && content !== "normal") {
            pseudo.push(content);
            if (which === "::before") words.push(content.startsWith('"') ? content.slice(1, -1) : content);
          }
        }
        const style = getComputedStyle(node);
        const box = node.getBoundingClientRect();
        const round = Number.parseFloat(style.borderTopLeftRadius) >= Math.min(box.width, box.height) / 2 - 0.5;
        const painted = style.backgroundColor !== "rgba(0, 0, 0, 0)" && style.backgroundColor !== "transparent";
        if (round && painted && box.width <= 10 && box.height <= 10) dots.push(node.className.toString());
        for (const child of node.childNodes) walk(child);
      };
      walk(button);
      return { text: words.join(" ").replace(/\s+/g, " ").trim(), pseudo, dots };
    });

  for (const [engine] of engines) {
    for (const variant of ["profile-default", "profile-update-pending"]) {
      test(`${engine}: ${variant}: the button reads the model, then its effort, with no dot between`, async () => {
        const page = await open(engine, variant);
        const { text, pseudo, dots } = await drawn(page);
        expect(text).toContain("Opus 5.5");
        expect(text).toContain("Medium");
        expect(text).toMatch(/Opus 5\.5\s+Medium/);
        expect(text).not.toMatch(/[•·∙●⋅]/);
        expect(pseudo.join(" ")).not.toMatch(/[•·∙●⋅]|\\2022|\\b7|\\00b7/i);
        expect(dots).toEqual([]);
        await page.close();
      });
    }
  }
});
