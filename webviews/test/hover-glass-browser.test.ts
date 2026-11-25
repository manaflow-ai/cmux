// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Every hover tooltip and hover preview draws glass (Leo, 2026-11-20: a bit more glass on the input
// box, and glass everywhere, especially on all the hover tooltips and hover previews). The static
// checks (hover-cards-glass.test.ts, check-glass-never-opaque.ts) read rules by selector; this reads
// the cascade itself: each surface's root, with the class list it renders with (browser/hoverSurfaces.ts),
// under the stylesheets of the pages that draw it, in real Chromium. Outside Reduce Transparency each
// one frosts what is under it (a backdrop-filter blur) under a translucent fill; under Reduce
// Transparency it is opaque with no blur. Before: the chat header's tool preview
// (HeaderToolPreview.tsx) was the solid elevated surface with no backdrop-filter.
//
// The file also fails when the page code opens a Tooltip, an AnchoredCard or a role="tooltip" surface
// whose own class is not in browser/hoverSurfaces.ts, so a new hover surface is checked from its
// first commit.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/hover-glass-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { HOVER_SURFACES } from "./browser/hoverSurfaces";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("hover-glass-browser.test.ts", async () => {
  const SRC = path.resolve(import.meta.dir, "../src");

  function sources(dir: string): string[] {
    return readdirSync(dir).flatMap((name) => {
      const file = path.join(dir, name);
      if (statSync(file).isDirectory()) return name === "node_modules" ? [] : sources(file);
      return name.endsWith(".tsx") && !/\.(gallery|test)\.tsx$/.test(name) ? [file] : [];
    });
  }

  /** The class names a hover surface's opening tag passes, from its string literals (a template's
   * arms included), without the shared ones every surface carries. */
  function ownClasses(tag: string): string[] {
    const at = tag.search(/\b(?:className|cardClassName)=/);
    if (at < 0) return [];
    const start = tag.indexOf("=", at) + 1;
    let end = start + 1;
    if (tag[start] === "{")
      for (let depth = 0, index = start; index < tag.length; index++) {
        if (tag[index] === "{") depth++;
        else if (tag[index] === "}" && --depth === 0) {
          end = index + 1;
          break;
        }
      }
    else end = tag.indexOf('"', start + 1) + 1;
    const value = tag.slice(start, end);
    const literals =
      tag[start] === '"'
        ? [value.slice(1, -1)]
        : [...value.matchAll(/["'`]([^"'`$]*)["'`]/g)].map((match) => match[1]!);
    return literals
      .flatMap((literal) => literal.split(/\s+/))
      .filter((name) => /^[a-z][\w-]*$/.test(name) && !name.startsWith("ui-"));
  }

  /** Every Tooltip, AnchoredCard (or its lazy twin) and role="tooltip" root the page code renders. */
  function hoverSurfacesInSource(): { file: string; classes: string[] }[] {
    const found: { file: string; classes: string[] }[] = [];
    for (const file of sources(SRC)) {
      const text = readFileSync(file, "utf8");
      for (const match of text.matchAll(/<(Tooltip|AnchoredCard|LazyCard)\b|<div\b(?=[^>]*role="tooltip")/g)) {
        let end = match.index! + match[0].length;
        for (let depth = 0; end < text.length; end++) {
          const char = text[end];
          if (char === "{") depth++;
          else if (char === "}") depth--;
          else if (char === ">" && depth === 0 && text[end - 1] !== "=") break;
        }
        const classes = ownClasses(text.slice(match.index!, end));
        if (classes.length > 0) found.push({ file: path.relative(SRC, file), classes });
      }
    }
    return found;
  }

  function alpha(color: string): number {
    const srgb = color.match(/color\(srgb\s+[\d.e-]+\s+[\d.e-]+\s+[\d.e-]+(?:\s*\/\s*([\d.e-]+))?\)/);
    if (srgb) return srgb[1] === undefined ? 1 : Number(srgb[1]);
    const rgb = color.match(/rgba?\(\s*[\d.]+[,\s]+[\d.]+[,\s]+[\d.]+(?:[,/\s]+([\d.]+))?\s*\)/);
    if (rgb) return rgb[1] === undefined ? 1 : Number(rgb[1]);
    throw new Error(`unparsed color ${color}`);
  }
  type Seen = { name: string; fill: string; image: string; backdrop: string };

  test("every hover surface the page code renders is in the harness's list", () => {
    const listed = new Set(HOVER_SURFACES.flatMap((surface) => surface.className.split(/\s+/)));
    const missing = hoverSurfacesInSource()
      .filter(({ classes }) => !classes.some((name) => listed.has(name)))
      .map(({ file, classes }) => `${file}: ${classes.join(" ")}`);
    expect(missing).toEqual([]);
  });

  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmViteServer(vite, "/test/browser/hover-glass.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function seen(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Seen[]> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, colorScheme });
    try {
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/hover-glass.html`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
      return await page.evaluate((attributes) => {
        for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
        return [...document.querySelectorAll<HTMLElement>("[data-surface]")].map((node) => {
          const style = getComputedStyle(node);
          return {
            name: node.dataset.surface!,
            fill: style.backgroundColor,
            image: style.backgroundImage,
            backdrop: style.backdropFilter,
          };
        });
      }, attributes);
    } finally {
      await page.close();
    }
  }

  const windows: { name: string; attributes: Record<string, string> }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "a see-through window", attributes: { "data-cmux-see-through": "" } },
  ];
  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: every hover tooltip and hover preview is glass`, async () => {
        const surfaces = await seen(colorScheme, window.attributes);
        expect(surfaces.map((surface) => surface.name)).toEqual(HOVER_SURFACES.map((surface) => surface.name));
        const seeThrough = "data-cmux-see-through" in window.attributes;
        const solid = surfaces
          .filter((surface) => {
            if (!surface.backdrop.includes("blur(")) return true;
            // A see-through page lays the tint (a gradient) over an underlay at the text floor
            // (glass.css TEXT ON GLASS KEEPS ITS FLOOR, --surface-text-min 92%): translucent, never opaque.
            if (seeThrough && surface.image.includes("gradient(")) return alpha(surface.fill) >= 1;
            return alpha(surface.fill) >= 0.9;
          })
          .map((surface) => `${surface.name}: ${surface.fill} / ${surface.backdrop}`);
        expect(solid).toEqual([]);
      });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, Reduce Transparency: every hover surface is opaque with no blur`, async () => {
      const surfaces = await seen(colorScheme, { "data-reduce-transparency": "" });
      const glassy = surfaces
        .filter((surface) => surface.backdrop !== "none" || alpha(surface.fill) < 1)
        .map((surface) => `${surface.name}: ${surface.fill} / ${surface.backdrop}`);
      expect(glassy).toEqual([]);
    });
});
