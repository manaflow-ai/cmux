// appearance.previousGlass (glass.css, PREVIOUS GLASS): the fold-away for the one glass system
// (design/glass-system.md, cmux#48174). The app sends glassLevels "previous" with the web theme and
// the bootstrap sets data-glass-levels="previous" on <html>; with it, every glass token is the number
// from before the system, the same numbers as the `now` arm of scripts/gallery/glass-system.capture.json
// (the arm the PR's before captures were drawn with), in light and dark alike. Without it the tokens
// are the design scale's. It also hands the secondary ink back to the page (the glass's own
// secondary ink is part of the system), and Reduce Transparency still draws the glass solid.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/previous-glass.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("previous-glass.test.ts", async () => {
  const webviews = path.resolve(import.meta.dir, "..");

  /** The `now` arm's token values: the first `{...}` block of the shot's arm CSS. */
  function nowArm(): Record<string, string> {
    const spec = JSON.parse(readFileSync(path.join(webviews, "scripts/gallery/glass-system.capture.json"), "utf8"));
    const css: string = spec.shots.find((shot: { name: string }) => shot.name === "glass-system").arms.now;
    const block = css.slice(css.indexOf("{") + 1, css.indexOf("}"));
    return Object.fromEntries(
      block
        .split(";")
        .map((pair) => pair.trim())
        .filter(Boolean)
        .map((pair) => [pair.slice(0, pair.indexOf(":")).trim(), pair.slice(pair.indexOf(":") + 1).trim()]),
    );
  }

  const designScale = JSON.parse(
    readFileSync(path.join(webviews, "../schemas/design-scale/design-scale.json"), "utf8"),
  );

  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("previous-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("previous glass", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/composer-rim.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: 1, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((attributes) => {
      for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
    }, attributes);
    return page;
  }

  const tokens = (page: Page, names: string[]) =>
    page.evaluate((names) => {
      const style = getComputedStyle(document.documentElement);
      return Object.fromEntries(names.map((name) => [name, style.getPropertyValue(name).trim()]));
    }, names);

  const norm = (value: string) => value.replace(/\s+/g, " ").replace(/\s*([(),])\s*/g, "$1");
  const previous = nowArm();

  for (const colorScheme of ["light", "dark"] as const) {
    test(`${colorScheme}: data-glass-levels="previous" brings back every glass number from before`, async () => {
      const page = await open(colorScheme, { "data-theme": colorScheme, "data-glass-levels": "previous" });
      const got = await tokens(page, Object.keys(previous));
      for (const [name, value] of Object.entries(previous)) expect(norm(got[name]!), name).toBe(norm(value));
      // The composer frosts at the old popover's 1.25 on an opaque window, and its material at the
      // old 1.8 over art.
      const backdrop = await page.evaluate(() => getComputedStyle(document.getElementById("composer")!).backdropFilter);
      expect(backdrop).toBe("blur(24px) saturate(1.25)");
      await page.close();
      const art = await open(colorScheme, {
        "data-theme": colorScheme,
        "data-glass-levels": "previous",
        "data-cmux-see-through": "",
        "data-glass": "plain",
      });
      const material = await art.evaluate(() => getComputedStyle(document.getElementById("composer")!).backdropFilter);
      expect(material).toContain("saturate(1.8)");
      await art.close();
    });

    test(`${colorScheme}: without it, the tokens are the one glass system's`, async () => {
      const page = await open(colorScheme, { "data-theme": colorScheme });
      const got = await tokens(page, [
        "--ds-glass-chrome-tint",
        "--ds-glass-menu-tint",
        "--ds-glass-saturation",
        "--ds-glass-underlay",
      ]);
      const level = (name: string) => designScale.glass.find((entry: { name: string }) => entry.name === name);
      const tint = (name: string) =>
        `${colorScheme === "dark" ? (level(name).darkTint ?? level(name).tint) : level(name).tint}%`;
      expect(got["--ds-glass-chrome-tint"]).toBe(tint("chrome"));
      expect(got["--ds-glass-menu-tint"]).toBe(tint("menu"));
      expect(got["--ds-glass-saturation"]).toBe(String(designScale.glassSaturation.value));
      // A menu that cannot blur in place covers the same 88% of the text under it in dark as in light
      // (rule 6): dark's clearer 72% menu sits over a heavier underlay, so the chat's text does not read
      // through the Model menu (hq#13923).
      const underlay = colorScheme === "dark" ? designScale.glassUnderlay.darkValue : designScale.glassUnderlay.value;
      expect(got["--ds-glass-underlay"]).toBe(`${underlay}%`);
      const menuTint = Number.parseFloat(got["--ds-glass-menu-tint"]!);
      const cover = menuTint + ((100 - menuTint) * Number.parseFloat(got["--ds-glass-underlay"]!)) / 100;
      expect(cover, `${colorScheme} menu cover`).toBeGreaterThanOrEqual(87.5);
      expect(cover, `${colorScheme} menu cover`).toBeLessThan(90);
      const backdrop = await page.evaluate(() => getComputedStyle(document.getElementById("composer")!).backdropFilter);
      expect(backdrop).toContain(`saturate(${designScale.glassSaturation.value})`);
      await page.close();
    });
  }

  test("the secondary ink on glass is the system's, and previous hands it back to the page", async () => {
    const ink = async (attributes: Record<string, string>) => {
      const page = await open("dark", { "data-theme": "dark", ...attributes });
      const value = await page.evaluate(() => {
        const probe = document.createElement("span");
        probe.style.color = "var(--cmux-text-secondary)";
        document.getElementById("composer")!.append(probe);
        const inside = getComputedStyle(probe).color;
        const outside = getComputedStyle(document.body).getPropertyValue("--cmux-text-secondary").trim();
        probe.remove();
        return { inside, outside };
      });
      await page.close();
      return value;
    };
    const system = await ink({});
    // The theme's text at the design scale's dark share, over the glass (an alpha, not a solid grey).
    const share = designScale.glassInk.darkSecondary / 100;
    expect(system.inside).toMatch(new RegExp(`/ ${share}\\)|, ${share}\\)`));
    const old = await ink({ "data-glass-levels": "previous" });
    expect(old.inside).not.toMatch(new RegExp(`/ ${share}\\)|, ${share}\\)`));
  });

  test("Reduce Transparency still draws the glass solid under the previous numbers", async () => {
    const page = await open("light", { "data-glass-levels": "previous", "data-reduce-transparency": "" });
    const look = await page.evaluate(() => {
      const style = getComputedStyle(document.getElementById("composer")!);
      return { fill: style.backgroundColor, backdrop: style.backdropFilter };
    });
    expect(look.backdrop).toBe("none");
    expect(look.fill).not.toMatch(/\/ 0\.|, 0\.\d+\)$/);
    await page.close();
  });
});
