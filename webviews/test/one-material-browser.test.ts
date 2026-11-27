// One material per surface, in the browser (design/glass-system.md, "One material per surface"; Leo,
// 2026-11-21, on the prompt rail's hover preview drawn as an opaque box: "shietttt this web thing got
// disconnected from its glass... where is our proper glass redesign?"). Each floating primitive, with
// the classes and host-glass mark its component's source gives it, in a see-through Chromium page:
//   - drawn by the App (data-host-glass-drawn="1"): the page lays nothing: fill alpha 0, no
//     backdrop-filter, no rim or shadow; the App's glass is its one material;
//   - not drawn (drawn="0": past the deadline, closing, an older App), over the composer
//     (data-glass-keeps-underlay) or a cover with nothing blurred in place: the page's one glass, a
//     translucent fill under a backdrop blur, never an opaque or a bare box;
//   - Reduce Transparency: the opaque surface, no blur.
// And no material inside a material: nothing in a surface draws a glass of its own.
//
// Before the fix the rail's card had no host-glass mark and painted its own 72% fill and blur outside
// .ui-glass: the mark test fails, and with the mark forced on, its drawn state keeps that fill.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/one-material-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("one-material-browser.test.ts", async () => {
  const source = (file: string) => readFileSync(path.join(import.meta.dir, "../src", file), "utf8");

  type Primitive = { name: string; classes: string; level: string; cover: boolean; role?: string; inner?: string };

  /** The class list and host-glass mark a component's source gives the element whose classes start `lead`. */
  function fromSource(file: string, lead: string): { classes: string; level: string | undefined; cover: boolean } {
    const text = source(file);
    const at = text.indexOf(`"${lead}`);
    if (at < 0) throw new Error(`${file}: no class list starting "${lead}"`);
    const classes = text.slice(at + 1, text.indexOf('"', at + 1));
    // The element's own attributes: up to its tag's end.
    const tag = text.slice(at, text.indexOf(">\n", at));
    const level = tag.match(/data-host-glass(?:"\s*:\s*|=)"(menu|popover|chip)"/)?.[1];
    return { classes, level, cover: /data-host-glass-cover/.test(tag) };
  }

  const HARNESS = "/test/browser/one-material.html";
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("one-material-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("one material", () => test("chromium", () => {}));
    return;
  }

  const card = fromSource("agent-session/acpmux/threadMinimap/PreviewCard.tsx", "acpmux-minimap__card");
  const primitives: Primitive[] = [
    { name: "menu", classes: "ui-popup ui-glass ui-menu", level: "menu", cover: true },
    { name: "popover", classes: "ui-popup ui-glass ui-popover", level: "popover", cover: true },
    { name: "tooltip", classes: "ui-tooltip ui-glass", level: "chip", cover: true },
    { name: "hover card", classes: "ui-tooltip ui-card ui-glass", level: "popover", cover: false },
    { name: "notice", classes: "ui-notice ui-glass", level: "popover", cover: false, role: "toast" },
    { name: "dialog", classes: "ui-dialog ui-glass ui-glass-floats", level: "popover", cover: false, role: "sheet" },
    { name: "rail preview card", classes: card.classes, level: card.level ?? "", cover: card.cover },
    // The GitHub link hover card (chips/LinkHoverCard.tsx) with its Open | chevron split, which drew a
    // framed capsule on the card's glass (Leo: "doubled up glass/wack looking glass").
    {
      name: "link hover card",
      classes: "ui-tooltip ui-card ui-glass cv-link-preview",
      level: "popover",
      cover: false,
      inner:
        '<div class="cv-link-preview__content"><div class="cv-link-preview__head"><span class="cv-link-preview__split">' +
        '<button type="button" class="cv-link-preview__open">Open</button>' +
        '<button type="button" class="acpmux-open-in acpmux-review-changes is-chevron">v</button></span></div></div>',
    },
  ];

  test("the rail's preview card is marked for the App's glass and wears .ui-glass", () => {
    expect(card.level).toBe("popover");
    expect(card.classes.split(" ")).toContain("ui-glass");
  });

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmViteServer(vite, HARNESS);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Look = { fill: string; image: string; backdrop: string; shadow: string; border: string; nested: string[] };

  async function open(colorScheme: "light" | "dark"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 640, height: 480 }, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${HARNESS}`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((colorScheme) => {
      document.documentElement.style.colorScheme = colorScheme;
    }, colorScheme);
    return page;
  }

  /** Mounts `primitive` under `root` attributes with `attributes` of its own, and reads its look. */
  async function look(
    page: Page,
    primitive: Primitive,
    root: Record<string, string>,
    attributes: Record<string, string>,
  ): Promise<Look> {
    return page.evaluate(
      ({ primitive, root, attributes }) => {
        const html = document.documentElement;
        for (const name of html.getAttributeNames())
          if (name.startsWith("data-") && name !== "data-harness-ready") html.removeAttribute(name);
        for (const [name, value] of Object.entries(root)) html.setAttribute(name, value);
        const stage = document.getElementById("stage")!;
        stage.replaceChildren();
        const element = document.createElement("div");
        element.className = primitive.classes;
        element.setAttribute("data-host-glass", primitive.level);
        if (primitive.cover) element.setAttribute("data-host-glass-cover", "");
        if (primitive.role) element.setAttribute("data-host-glass-role", primitive.role);
        for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
        Object.assign(element.style, {
          position: "absolute",
          top: "40px",
          left: "40px",
          width: "240px",
          height: "120px",
        });
        // What a surface holds: a row, a plain button and a line of text.
        element.innerHTML =
          primitive.inner ??
          '<div class="ui-menu-item" role="menuitem">Row</div><button class="ui-button" type="button">Open</button><p>Text</p>';
        stage.append(element);
        const style = getComputedStyle(element);
        // A material inside it: anything with a backdrop filter or a glass class of its own, or a
        // group of controls framed all round (a capsule that reads as a second glass on the frost).
        const seen = (color: string) => !/^(transparent|rgba\(0, 0, 0, 0\))$/.test(color) && !color.endsWith("/ 0)");
        const framed = (own: CSSStyleDeclaration) =>
          (["Top", "Right", "Bottom", "Left"] as const).every(
            (side) =>
              parseFloat(own.getPropertyValue(`border-${side.toLowerCase()}-width`)) > 0 &&
              own.getPropertyValue(`border-${side.toLowerCase()}-style`) !== "none" &&
              seen(own.getPropertyValue(`border-${side.toLowerCase()}-color`)),
          );
        const nested = [...element.querySelectorAll<HTMLElement>("*")]
          .filter((inner) => {
            const own = getComputedStyle(inner);
            return (
              inner.classList.contains("ui-glass") ||
              inner.hasAttribute("data-host-glass") ||
              (own.backdropFilter !== "none" && own.backdropFilter !== "") ||
              (inner.querySelectorAll("button").length > 1 && framed(own))
            );
          })
          .map((inner) => inner.outerHTML.slice(0, 80));
        return {
          fill: style.backgroundColor,
          image: style.backgroundImage,
          backdrop: style.backdropFilter,
          shadow: style.boxShadow,
          border: style.borderTopColor,
          nested,
        };
      },
      { primitive, root, attributes },
    );
  }

  /** The alpha of a computed color (`rgb()`, `rgba()` or `color(srgb ...)`). */
  function alpha(color: string): number {
    if (color === "transparent") return 0;
    const srgb = color.match(/color\(srgb [\d.e-]+ [\d.e-]+ [\d.e-]+(?: \/ ([\d.e-]+))?\)/);
    if (srgb) return srgb[1] === undefined ? 1 : Number(srgb[1]);
    const parts = color.match(/[\d.]+/g) ?? [];
    return parts.length > 3 ? Number(parts[3]) : 1;
  }

  const SEE_THROUGH = { "data-cmux-see-through": "", "data-glass": "plain", "data-host-glass-on": "" };
  const pageGlass = (found: Look, label: string) => {
    // A material: a translucent fill (its color or the underlay gradient) under a blur; never opaque.
    expect(found.image !== "none" || alpha(found.fill) > 0, `${label}: some fill`).toBe(true);
    if (found.image === "none") expect(alpha(found.fill), `${label}: never opaque`).toBeLessThan(1);
    expect(found.backdrop, `${label}: its blur`).not.toBe("none");
  };

  for (const colorScheme of ["light", "dark"] as const)
    for (const primitive of primitives) {
      test(`${colorScheme}, ${primitive.name}: on the App's glass the page lays nothing of its own`, async () => {
        const page = await open(colorScheme);
        const attributes: Record<string, string> = { "data-host-glass-drawn": "1" };
        // A cover goes clear only where the page under it blurs in place.
        if (primitive.cover) attributes["data-glass-over"] = "";
        const found = await look(page, primitive, SEE_THROUGH, attributes);
        expect(alpha(found.fill), "fill").toBe(0);
        expect(found.image, "underlay").toBe("none");
        expect(found.backdrop, "backdrop").toBe("none");
        expect(found.shadow, "rim and shadow").toBe("none");
        expect(alpha(found.border), "border").toBe(0);
        expect(found.nested).toEqual([]);
        await page.close();
      });

      test(`${colorScheme}, ${primitive.name}: every state the App does not draw is the page's one glass`, async () => {
        const page = await open(colorScheme);
        const states: [string, Record<string, string>, Record<string, string>][] = [
          ["not drawn", SEE_THROUGH, { "data-host-glass-drawn": "0" }],
          ["closing", SEE_THROUGH, { "data-host-glass-drawn": "0", "data-ending-style": "" }],
          ["over the composer", SEE_THROUGH, { "data-host-glass-drawn": "1", "data-glass-keeps-underlay": "" }],
          ["an opaque page", {}, {}],
        ];
        if (primitive.cover)
          states.push(["a cover with nothing blurred", SEE_THROUGH, { "data-host-glass-drawn": "1" }]);
        for (const [state, root, attributes] of states) {
          const found = await look(page, primitive, root, attributes);
          pageGlass(found, `${primitive.name}, ${state}`);
          expect(found.nested, state).toEqual([]);
        }
        await page.close();
      });

      test(`${colorScheme}, ${primitive.name}: Reduce Transparency is the opaque surface`, async () => {
        const page = await open(colorScheme);
        const found = await look(page, primitive, { "data-cmux-see-through": "", "data-reduce-transparency": "" }, {});
        expect(found.backdrop).toBe("none");
        expect(found.image === "none" ? alpha(found.fill) : 1).toBe(1);
        await page.close();
      });
    }
});
